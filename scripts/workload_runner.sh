#!/bin/bash
set -euo pipefail

# =========================
# workload_runner.sh
# Runs: sysbench (cpu + memory), pgbench (Postgres OLTP)
# Collects vmstat/iostat and outputs JSON/plaintext into OUTDIR, uploads to GCS
# Usage: workload_runner.sh <WORKLOAD> <WARMUP_SEC> <RUN_TIME_SEC> <GCS_OUT>
# Example: sudo ./workload_runner.sh all 60 300 gs://my-bucket/results/my-instance
# =========================

WORKLOAD=${1:-all}         # "all" or comma-separated list: cpu,mem,pgbench
WARMUP=${2:-60}
RUN_TIME=${3:-300}
GCS_OUT=${4:-}
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
  while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     || sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1 \
     || sudo fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
    sleep 5
  done
  log "Apt locks cleared."
}

enable_repos() {
  log "Ensuring Ubuntu repos (main, universe, multiverse) are enabled..."
  sudo add-apt-repository -y main || true
  sudo add-apt-repository -y universe || true
  sudo add-apt-repository -y multiverse || true
  sudo add-apt-repository -y restricted || true
}

safe_apt_install() {
  wait_for_apt_locks
  retry 5 sudo apt-get update -y
  retry 3 sudo apt-get install -y --no-install-recommends "$@" || return 1
}

capture_instance_metadata() {
  curl -s -f -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/?recursive=true" > "$INSTANCE_META_JSON" || true
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
    log "Installing gsutil..."
    set +e
    sudo apt-get update -y && sudo apt-get install -y google-cloud-sdk || true
    set -e
    if command -v gsutil >/dev/null 2>&1; then
      gsutil -m cp -r "$OUTDIR" "$GCS_OUT" || log "⚠️ Upload to GCS failed"
    else
      log "⚠️ gsutil still missing. Skipping upload."
    fi
  fi
}

ensure_tools() {
  enable_repos
  log "Installing required packages (sysbench jq curl git dstat sysstat postgresql)..."
  safe_apt_install jq curl git dstat sysstat sysbench postgresql postgresql-client build-essential
  log "Tool install complete."
}

# -------------------------
# System monitoring helpers
# -------------------------
start_sysmon() {
  local prefix=$1
  mkdir -p "$OUTDIR/metrics"
  vmstat 1 > "$OUTDIR/metrics/${prefix}_vmstat.txt" &
  VMSTAT_PID=$!
  iostat -dx 1 > "$OUTDIR/metrics/${prefix}_iostat.txt" &
  IOSTAT_PID=$!
  log "Started sysmon collectors"
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

top_snapshot() {
  top -b -n1 > "$OUTDIR/metrics/top-$(date +%s).txt" || true
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
  jq --arg nm "$name" --slurpfile txt "$OUTDIR/${name}_run.txt" \
     '.tests[$nm] = {raw: ($txt[0] | tostring), type:"sysbench_cpu"}' "$RESULTS_JSON" > "$RESULTS_JSON.tmp" && mv "$RESULTS_JSON.tmp" "$RESULTS_JSON"
}

run_sysbench_memory() {
  local name="memory"
  log "=== SYSBENCH MEMORY test ==="
  start_sysmon "$name"
  sysbench memory --memory-block-size=1K --memory-total-size=1G \
    --threads=$(nproc) --time="$RUN_TIME" run > "$OUTDIR/${name}_run.txt" 2>&1 || true
  stop_sysmon
  top_snapshot
  jq --arg nm "$name" --slurpfile txt "$OUTDIR/${name}_run.txt" \
     '.tests[$nm] = {raw: ($txt[0] | tostring), type:"sysbench_memory"}' "$RESULTS_JSON" > "$RESULTS_JSON.tmp" && mv "$RESULTS_JSON.tmp" "$RESULTS_JSON"
}

run_pgbench() {
  local name="pgbench"
  log "=== PostgreSQL OLTP test ==="
  sudo systemctl enable --now postgresql || true
  sudo -u postgres psql -c "CREATE DATABASE benchdb;" || true
  sudo -u postgres psql -d benchdb -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" || true
  log "Initializing pgbench scale=50"
  sudo -u postgres pgbench -i -s 50 benchdb > "$OUTDIR/${name}_init.txt" 2>&1 || true
  log "Running pgbench test..."
  CL=$(nproc)
  JT=$((CL/2>0?CL/2:1))
  sudo -u postgres pgbench -c "$CL" -j "$JT" -T "$RUN_TIME" -r benchdb > "$OUTDIR/${name}_run.txt" 2>&1 || true
  top_snapshot
  jq --arg nm "$name" --slurpfile r "$OUTDIR/${name}_run.txt" \
     '.tests[$nm] = {raw: ($r[0] | tostring), type:"pgbench"}' "$RESULTS_JSON" > "$RESULTS_JSON.tmp" && mv "$RESULTS_JSON.tmp" "$RESULTS_JSON"
}

# -------------------------
# Main
# -------------------------
trap 'rc=$?; log "Trap exit code=$rc"; upload_results; exit $rc' EXIT

capture_instance_metadata
jq -n '{instance:{}, tests:{}}' > "$RESULTS_JSON"

ensure_tools

IFS=',' read -r -a WORKLOADS <<< "$WORKLOAD"
if [[ " ${WORKLOADS[*]} " =~ " all " ]]; then
  WORKLOADS=(cpu memory pgbench)
fi

for t in "${WORKLOADS[@]}"; do
  case "$t" in
    cpu) run_sysbench_cpu ;;
    memory) run_sysbench_memory ;;
    pgbench) run_pgbench ;;
    *) log "Unknown workload $t, skipping" ;;
  esac
  log "Completed test: $t"
  sleep 5
done

jq --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" '.run_completed_at=$ts' "$RESULTS_JSON" > "$RESULTS_JSON.tmp" && mv "$RESULTS_JSON.tmp" "$RESULTS_JSON"
upload_results
log "✅ All workloads completed. Results in $OUTDIR"
exit 0
