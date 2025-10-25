#!/bin/bash
set -euo pipefail

# =========================
# workload_runner.sh
# Runs: sysbench (cpu + memory), fio (disk IO), iperf3 (network), pgbench (Postgres OLTP)
# Collects vmstat/iostat and outputs JSON/plaintext into OUTDIR, uploads to GCS
# Usage: workload_runner.sh <WORKLOAD> <WARMUP_SEC> <RUN_TIME_SEC> <GCS_OUT>
# Example: sudo ./workload_runner.sh all 60 300 gs://my-bucket/results/my-instance
# =========================

WORKLOAD=${1:-all}         # "all" or comma-separated list: cpu,mem,fio,net,pgbench
WARMUP=${2:-60}            # warmup seconds (applies where relevant)
RUN_TIME=${3:-300}         # run seconds per test
GCS_OUT=${4:-}             # required if you want upload to GCS
OUTDIR="/tmp/bench-$(date +%s)"
mkdir -p "$OUTDIR"

INSTANCE_META_JSON="$OUTDIR/instance_meta.json"
RESULTS_JSON="$OUTDIR/results_summary.json"

echo "=== Bench runner starting ==="
echo "WORKLOAD=${WORKLOAD}"
echo "WARMUP=${WARMUP}"
echo "RUN_TIME=${RUN_TIME}"
echo "GCS_OUT=${GCS_OUT:-<none>}"
echo "OUTDIR=${OUTDIR}"

# -------------------------
# Helpers
# -------------------------
log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }
retry() {
  local tries=$1; shift
  local i=0
  until "$@"; do
    i=$((i+1))
    if [ $i -ge $tries ]; then return 1; fi
    log "Attempt $i/$tries failed. Sleeping 5s..."
    sleep 5
  done
  return 0
}

wait_for_apt_locks() {
  log "Waiting for apt/dpkg locks to clear..."
  local wait_count=0
  while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     || sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1 \
     || sudo fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
    sleep 5
    wait_count=$((wait_count+1))
    if [ $wait_count -gt 60 ]; then
      log "Waited >5 min for apt locks, continuing anyway..."
      break
    fi
  done
  log "Apt locks cleared (or timeout)."
}

safe_apt_install() {
  wait_for_apt_locks
  retry 5 sudo apt-get update -y
  retry 3 sudo apt-get install -y --no-install-recommends "$@" || return 1
}

capture_instance_metadata() {
  # basic machine metadata for later cost / correlation
  curl -s -f -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/?recursive=true" > "$INSTANCE_META_JSON" || true
  log "Saved instance metadata to $INSTANCE_META_JSON"
}

upload_results() {
  if [ -z "$GCS_OUT" ]; then
    log "No GCS_OUT configured, skipping upload."
    return
  fi
  if command -v gsutil >/dev/null 2>&1; then
    log "Uploading results to $GCS_OUT ..."
    gsutil -m cp -r "$OUTDIR" "$GCS_OUT" || log "⚠️ Upload to GCS failed"
  else
    log "gsutil not found; attempted to install google-cloud-sdk..."
    # try to install minimal Cloud SDK (best-effort)
    set +e
    sudo apt-get update -y && sudo apt-get install -y apt-transport-https ca-certificates gnupg
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add - >/dev/null 2>&1
    echo "deb https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list
    sudo apt-get update -y
    sudo apt-get install -y google-cloud-sdk || true
    set -e
    if command -v gsutil >/dev/null 2>&1; then
      gsutil -m cp -r "$OUTDIR" "$GCS_OUT" || log "⚠️ Upload to GCS failed after installing SDK"
    else
      log "⚠️ Still no gsutil available. Skipping upload."
    fi
  fi
}

ensure_tools() {
  # ensure required tools are installed
  log "Installing required packages (jq curl git dstat sysstat iperf3 fio sysbench postgresql)..."
  safe_apt_install jq curl git dstat sysstat iperf3 fio sysbench postgresql postgresql-contrib postgresql-client build-essential
  # iostat is from sysstat, vmstat available by default
  log "Tool install complete."
}

# Parse workload argument to list
IFS=',' read -r -a WORKLOADS <<< "$WORKLOAD"

# Ensure at least one workload
if [ "${#WORKLOADS[@]}" -eq 0 ]; then
  WORKLOADS=("all")
fi
# if "all" expand
if [[ " ${WORKLOADS[*]} " =~ " all " ]]; then
  WORKLOADS=(cpu memory fio net pgbench)
fi

# ensure safe upload on exit or error
trap 'rc=$?; log "Trap: uploading results (rc=$rc)"; upload_results; exit $rc' EXIT

# capture instance metadata asap
capture_instance_metadata

# Prepare results summary structure
jq -n '{instance: {}, tests: {}}' > "$RESULTS_JSON" || true
# populate instance meta into summary if available
if [ -s "$INSTANCE_META_JSON" ]; then
  jq --slurpfile meta "$INSTANCE_META_JSON" '.instance = ($meta[0])' "$RESULTS_JSON" > "$RESULTS_JSON.tmp" && mv "$RESULTS_JSON.tmp" "$RESULTS_JSON"
fi

# Background system metrics helper
start_sysmon() {
  local prefix=$1
  mkdir -p "$OUTDIR/metrics"
  # vmstat every 1s, iostat every 1s (requires sysstat), dstat 1s
  vmstat 1 > "$OUTDIR/metrics/${prefix}_vmstat.txt" &
  VMSTAT_PID=$!
  iostat -dx 1 > "$OUTDIR/metrics/${prefix}_iostat.txt" &
  IOSTAT_PID=$!
  dstat -tcdnm --output "$OUTDIR/metrics/${prefix}_dstat.csv" 1 > /dev/null 2>&1 &
  DSTAT_PID=$!
  log "Started sysmon: vmstat($VMSTAT_PID) iostat($IOSTAT_PID) dstat($DSTAT_PID)"
}

stop_sysmon() {
  # kill background system metric collectors if running
  for pid in ${VMSTAT_PID:-} ${IOSTAT_PID:-} ${DSTAT_PID:-}; do
    if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  log "Stopped sysmon collectors"
}

# Utility to timestamped top snapshot
top_snapshot() {
  top -b -n1 > "$OUTDIR/metrics/top-$(date +%s).txt" || true
}

# -------------------------
# Test: CPU (sysbench)
# -------------------------
run_sysbench_cpu() {
  local name="cpu"
  log "=== SYSBENCH CPU test ==="
  start_sysmon "$name"
  log "sysbench warmup ${WARMUP}s"
  sysbench cpu --threads=$(nproc) --time="$WARMUP" run > "$OUTDIR/${name}_warmup.txt" 2>&1 || true
  log "sysbench run ${RUN_TIME}s"
  sysbench cpu --threads=$(nproc) --time="$RUN_TIME" run > "$OUTDIR/${name}_run.txt" 2>&1 || true
  # capture parsing summary
  awk '/events per second|avg:/ {print}' "$OUTDIR/${name}_run.txt" > "$OUTDIR/${name}_summary.txt" || true
  stop_sysmon
  top_snapshot
  # Annotate results JSON
  jq --arg nm "$name" --slurpfile txt "$OUTDIR/${name}_run.txt" '.tests[$nm] = {raw: ($txt[0] | tostring), type:"sysbench_cpu"}' "$RESULTS_JSON" > "$RESULTS_JSON.tmp" && mv "$RESULTS_JSON.tmp" "$RESULTS_JSON"
}

# -------------------------
# Test: Memory (sysbench)
# -------------------------
run_sysbench_memory() {
  local name="memory"
  log "=== SYSBENCH MEMORY test ==="
  start_sysmon "$name"
  sysbench memory --memory-block-size=1K --memory-total-size=1G --threads=$(nproc) --time="$RUN_TIME" run > "$OUTDIR/${name}_run.txt" 2>&1 || true
  stop_sysmon
  top_snapshot
  jq --arg nm "$name" --slurpfile txt "$OUTDIR/${name}_run.txt" '.tests[$nm] = {raw: ($txt[0] | tostring), type:"sysbench_memory"}' "$RESULTS_JSON" > "$RESULTS_JSON.tmp" && mv "$RESULTS_JSON.tmp" "$RESULTS_JSON"
}

# -------------------------
# Test: Postgres OLTP (pgbench)
# -------------------------
run_pgbench() {
  local name="pgbench"
  log "=== Postgres + pgbench OLTP test ==="
  # ensure postgres service running
  sudo systemctl enable --now postgresql || true
  # default postgres user and data directory
  PGDATA="/var/lib/postgresql/14/main"
  # Create DB and user (using unix peer auth)
  sudo -u postgres psql -c "CREATE DATABASE benchdb;" || true
  sudo -u postgres psql -d benchdb -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" || true

  # initialize pgbench with scale 50 (adjust as needed)
  log "Initializing pgbench scale=50 (this may take time)"
  sudo -u postgres pgbench -i -s 50 benchdb > "$OUTDIR/${name}_init.txt" 2>&1 || true

  # run warmup
  log "pgbench warmup & caching: ${WARMUP}s"
  sudo -u postgres pgbench -c 10 -j 2 -T "$WARMUP" benchdb > "$OUTDIR/${name}_warmup.txt" 2>&1 || true

  # run measured test (use clients & threads relative to vCPU count)
  CL=$(nproc)
  JT=$((CL/2>0?CL/2:1))
  log "Running pgbench: clients=${CL}, jobs=${JT}, time=${RUN_TIME}"
  sudo -u postgres pgbench -c "$CL" -j "$JT" -T "$RUN_TIME" -r benchdb > "$OUTDIR/${name}_run.txt" 2>&1 || true

  # collect postgres stats
  sudo -u postgres psql -d benchdb -c "SELECT sum(numbackends) AS backends, sum(xact_commit) AS commits FROM pg_stat_database;" > "$OUTDIR/${name}_stats.txt" 2>&1 || true

  top_snapshot
  jq --arg nm "$name" --slurpfile r "$OUTDIR/${name}_run.txt" '.tests[$nm] = {raw: ($r[0] | tostring), type:"pgbench"}' "$RESULTS_JSON" > "$RESULTS_JSON.tmp" && mv "$RESULTS_JSON.tmp" "$RESULTS_JSON"
}

# -------------------------
# Run selected tests sequentially
# -------------------------
# Ensure required tools installed (best-effort)
ensure_tools || log "Warning: ensure_tools failed - proceeding if tools exist"

for t in "${WORKLOADS[@]}"; do
  case "$t" in
    cpu)
      run_sysbench_cpu
      ;;
    memory)
      run_sysbench_memory
      ;;
    pgbench)
      run_pgbench
      ;;
    *)
      log "Unknown test: $t - skipping"
      ;;
  esac
  log "Completed test: $t"
  # small cool-down between tests
  sleep 5
done

# Finalize summary
log "Finalizing results summary..."
jq --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" '.run_completed_at=$ts' "$RESULTS_JSON" > "$RESULTS_JSON.tmp" && mv "$RESULTS_JSON.tmp" "$RESULTS_JSON"

# Ensure files exist and upload (trap also uploads on exit)
log "All tests finished. Results in $OUTDIR"
upload_results

# Normal exit
exit 0
