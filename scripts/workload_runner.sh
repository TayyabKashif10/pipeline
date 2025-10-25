#!/usr/bin/env bash
set -euo pipefail

# =========================
# Usage: sudo ./workload_runner_fixed.sh <WORKLOAD> <WARMUP_SEC> <RUN_TIME_SEC> <GCS_OUT>
# =========================


WORKLOAD=${1:-all}         # "all" or comma-separated list: cpu,mem,pgbench
WARMUP=${2:-60}
RUN_TIME=${3:-300}
# where results will be saved in storage bucket
GCS_OUT=${4:-}
# where results will be saved locally
OUTDIR="/tmp/bench-$(date -u +%s)"
mkdir -p "$OUTDIR"

RESULTS_JSON="$OUTDIR/results_summary.json"
INSTANCE_META_JSON="$OUTDIR/instance_meta.json"

# collect default starts VMSTAT and IOSTAT
VMSTAT_PID=""
IOSTAT_PID=""

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }

# Utility to retry commands that fail (due to resource contention etc), make the system more robust
retry() {
  # retry <tries> <cmd...>
  # tries == 0 => infinite
  local tries=$1; shift
  local i=0
  while :; do
    if "$@"; then
      return 0
    fi
    i=$((i+1))
    if [ "$tries" -ne 0 ] && [ $i -ge $tries ]; then
      return 1
    fi
    log "Attempt $i/${tries:-infinite} failed. Sleeping 5s..."
    sleep 5
  done
}

# these were required since a lot of the resources needed to run the commands kept getting locked.
# this attempts to acquire locks and waits until it doesn't get them.

wait_for_apt_locks() {
  log "Waiting for apt/dpkg locks to clear..."
  while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     || sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1 \
     || sudo fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
    sleep 5
  done
  log "Apt locks cleared."
}

# stop background jobs that may contend for apt
quiesce_apt_background_jobs() {
  log "Stopping/masking apt background services (best-effort)"
  sudo systemctl stop apt-daily.service apt-daily-upgrade.service unattended-upgrades.service || true
  sudo systemctl disable apt-daily.service apt-daily-upgrade.service unattended-upgrades.service || true
  sudo systemctl mask apt-daily.service apt-daily-upgrade.service || true
  sudo pkill -9 -f apt || true
  sudo pkill -9 -f unattended-upgrade || true
  wait_for_apt_locks
}

# enable some repos that are disabled by default (some were required for benchmarks)
enable_repos() {
  log "Enabling disabled repo"
  sudo sed -i 's/^#\s*\(deb .*\)/\1/' /etc/apt/sources.list || true
  sudo find /etc/apt/sources.list.d -type f -name "*.list" -exec sed -i 's/^#\s*\(deb .*\)/\1/' {} \; || true
  wait_for_apt_locks
}

safe_apt_install() {
  quiesce_apt_background_jobs
  retry 0 sudo apt-get update -y
  retry 0 sudo apt-get install -y --no-install-recommends "$@"
}

# -------------------------
# Dependencies for the testbenches
# -------------------------
ensure_tools() {
  enable_repos
  log "Installing required packages..."
  safe_apt_install jq curl git dstat sysstat sysbench postgresql postgresql-client build-essential
  log "Required tools installed"
}

# data of the VM instance.
capture_instance_metadata() {
  log "Capturing instance metadata (if running on GCE)"
  if command -v curl >/dev/null 2>&1; then
    curl -s -f -H "Metadata-Flavor: Google" \
      "http://metadata.google.internal/computeMetadata/v1/?recursive=true" > "$INSTANCE_META_JSON" 2>/dev/null || true
    log "Saved instance metadata to $INSTANCE_META_JSON"
  else
    log "curl missing; skipping instance metadata capture"
  fi
}

# upload local results to google storage bucket
upload_results() {
  if [ -z "$GCS_OUT" ]; then
    log "No GCS_OUT configured; skipping upload"
    return
  fi
  if command -v gsutil >/dev/null 2>&1; then
    log "Uploading results to $GCS_OUT"
    gsutil -m cp -r "$OUTDIR" "$GCS_OUT" || log "⚠️ Upload failed"
    return
  fi
}

# -------------------------
# System monitoring (VMSTAT, IOSTAT)
# -------------------------
start_sysmon() {
  local prefix=$1
  mkdir -p "$OUTDIR/metrics"
  vmstat 1 > "$OUTDIR/metrics/${prefix}_vmstat.txt" &
  VMSTAT_PID=$!
  iostat -dx 1 > "$OUTDIR/metrics/${prefix}_iostat.txt" &
  IOSTAT_PID=$!
  log "Started sysmon collectors (vmstat pid=$VMSTAT_PID, iostat pid=$IOSTAT_PID)"
}

stop_sysmon() {
  for pid in ${VMSTAT_PID:-} ${IOSTAT_PID:-}; do
    if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  log "Stopped sysmon collectors"
}

# process activity, also logged
top_snapshot() {
  top -b -n1 > "$OUTDIR/metrics/top-$(date -u +%s).txt" || true
}

# -------------------------
# Result helpers
# -------------------------
write_result_raw() {
  # write_result_raw <testname> <file>
  local testname=$1 file=$2
  # use --rawfile to safely embed text output as JSON string
  if [ -f "$file" ]; then
    jq --arg nm "$testname" --rawfile txt "$file" '.tests[$nm] = {raw: $txt, captured_at: (now|todate), type: $nm}' "$RESULTS_JSON" > "$RESULTS_JSON.tmp" && mv "$RESULTS_JSON.tmp" "$RESULTS_JSON" || true
  else
    jq --arg nm "$testname" '.tests[$nm] = {raw: "<no output>", captured_at: (now|todate), type: $nm}' "$RESULTS_JSON" > "$RESULTS_JSON.tmp" && mv "$RESULTS_JSON.tmp" "$RESULTS_JSON" || true
  fi
}

# -------------------------
# Benchmarks
# -------------------------
run_sysbench_cpu() {
  local name="cpu"
  log "=== SYSBENCH CPU test ==="
  start_sysmon "$name"
  sysbench cpu --threads=$(nproc) --time="$WARMUP" run > "$OUTDIR/${name}_warmup.txt" 2>&1 || true
  sysbench cpu --threads=$(nproc) --time="$RUN_TIME" run > "$OUTDIR/${name}_run.txt" 2>&1 || true
  stop_sysmon
  top_snapshot
  write_result_raw "$name" "$OUTDIR/${name}_run.txt"
}

run_sysbench_memory() {
  local name="memory"
  log "=== SYSBENCH MEMORY test ==="
  start_sysmon "$name"
  sysbench memory --memory-block-size=1K --memory-total-size=1G --threads=$(nproc) --time="$RUN_TIME" run > "$OUTDIR/${name}_run.txt" 2>&1 || true
  stop_sysmon
  top_snapshot
  write_result_raw "$name" "$OUTDIR/${name}_run.txt"
}

run_pgbench() {
  local name="pgbench"
  log "=== PostgreSQL OLTP test ==="
  sudo systemctl enable --now postgresql || true
  # create DB if missing
  sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname = 'benchdb'" | grep -q 1 || sudo -u postgres psql -c "CREATE DATABASE benchdb;" || true
  sudo -u postgres psql -d benchdb -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" || true
  log "Initializing pgbench scale=50"
  sudo -u postgres pgbench -i -s 50 benchdb > "$OUTDIR/${name}_init.txt" 2>&1 || true
  log "Running pgbench test..."
  local CL=$(nproc)
  local JT=$((CL/2>0?CL/2:1))
  sudo -u postgres pgbench -c "$CL" -j "$JT" -T "$RUN_TIME" -r benchdb > "$OUTDIR/${name}_run.txt" 2>&1 || true
  top_snapshot
  write_result_raw "$name" "$OUTDIR/${name}_run.txt"
}

# -------------------------
# Main flow
# -------------------------
main() {
  trap 'rc=$?; log "Trap exit code=$rc"; upload_results; exit $rc' EXIT

  log "=== Bench runner starting ==="
  log "WORKLOAD=${WORKLOAD} WARMUP=${WARMUP} RUN_TIME=${RUN_TIME} GCS_OUT=${GCS_OUT:-<none>} OUTDIR=${OUTDIR}"

  ensure_tools
  capture_instance_metadata

  # initialize results JSON
  jq -n '{instance: {}, tests: {}, run_started_at: (now|todate)}' > "$RESULTS_JSON"

  IFS=',' read -r -a WORKLOADS <<< "$WORKLOAD"

  # expand "all"
  local found_all=0
  for t in "${WORKLOADS[@]}"; do
    if [[ "$t" == "all" ]]; then
      found_all=1
      break
    fi
  done
  if [[ "$found_all" -eq 1 ]]; then
    log "Expanding 'all' to: cpu, memory, pgbench"
    WORKLOADS=(cpu memory pgbench)
  fi

  for t in "${WORKLOADS[@]}"; do
    case "$t" in
    #   cpu) run_sysbench_cpu ;;
      memory) run_sysbench_memory ;;
    #   pgbench) run_pgbench ;;
      *) log "Unknown workload $t, skipping" ;;
    esac
    log "Completed test: $t"
    sleep 2
  done

  jq --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" '.run_completed_at=$ts' "$RESULTS_JSON" > "$RESULTS_JSON.tmp" && mv "$RESULTS_JSON.tmp" "$RESULTS_JSON" || true
  upload_results
  log "✅ All workloads completed. Results in $OUTDIR"
}

# run
main "$@"
