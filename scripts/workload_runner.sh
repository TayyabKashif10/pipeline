#!/bin/bash
set -euo pipefail

LOG_FILE="/tmp/workload_runner.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

retry() {
  local retries=$1; shift
  local count=0
  until "$@"; do
    exit_code=$?
    count=$((count + 1))
    if [ $count -lt $retries ]; then
      log "Retry $count/$retries for command: $*"
      sleep 5
    else
      log "Command failed after $retries attempts: $*"
      return $exit_code
    fi
  done
}

wait_for_apt_locks() {
  while sudo fuser /var/{lib/{dpkg,apt/lists},cache/apt/archives}/lock >/dev/null 2>&1; do
    log "Waiting for apt locks..."
    sleep 5
  done
}

ensure_tools() {
  log "Installing required packages (jq curl git sysstat dstat sysbench postgresql)..."

  # Enable missing repositories
  sudo add-apt-repository -y universe || true
  sudo add-apt-repository -y multiverse || true
  sudo add-apt-repository -y "deb http://archive.ubuntu.com/ubuntu $(lsb_release -sc)-updates main universe multiverse" || true

  wait_for_apt_locks
  retry 5 sudo apt-get update -y

  # Install only what we actually need
  retry 3 sudo apt-get install -y --no-install-recommends \
    jq curl git sysstat dstat sysbench postgresql postgresql-client postgresql-contrib || {
      log "⚠️ Package install failed — retrying with fallback sources..."
      sudo apt-get update --allow-releaseinfo-change -y || true
      sudo apt-get install -y sysbench postgresql || true
    }

  log "Tool installation complete."
}

run_cpu_benchmark() {
  log "Running CPU benchmark..."
  sysbench cpu --cpu-max-prime=20000 run | tee -a "$LOG_FILE"
}

run_memory_benchmark() {
  log "Running Memory benchmark..."
  sysbench memory --memory-block-size=1M --memory-total-size=10G run | tee -a "$LOG_FILE"
}

run_pgbench() {
  log "Setting up PostgreSQL benchmark..."
  sudo service postgresql start || true
  sudo -u postgres psql -c "CREATE DATABASE benchmark;" || true
  sudo -u postgres pgbench -i benchmark
  log "Running pgbench workload..."
  sudo -u postgres pgbench -c 10 -T 30 benchmark | tee -a "$LOG_FILE"
}

collect_metrics() {
  log "Collecting system metrics..."
  mkdir -p /tmp/metrics
  dstat --time --cpu --mem --disk --net --output /tmp/metrics/dstat.csv 10 6 &
  DSTAT_PID=$!
  sleep 65
  kill $DSTAT_PID || true
  log "Metrics collected in /tmp/metrics"
}

upload_logs() {
  local bucket="$1"
  local vm_name
  vm_name=$(hostname)

  log "Uploading logs to gs://$bucket/${vm_name}_logs/"
  gsutil -m cp "$LOG_FILE" "gs://$bucket/${vm_name}_logs/workload.log" || true
  gsutil -m cp -r /tmp/metrics "gs://$bucket/${vm_name}_logs/metrics/" || true
  log "Logs uploaded successfully."
}

main() {
  if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <bucket_name> <workloads>"
    exit 1
  fi

  BUCKET_NAME="$1"
  WORKLOADS=(${2//,/ })

  ensure_tools

  # Expand keywords
  if [[ " ${WORKLOADS[*]} " =~ " all " ]]; then
    WORKLOADS=(cpu memory pgbench)
  fi

  # Compatibility for “sysbench” keyword
  if [[ " ${WORKLOADS[*]} " =~ " sysbench " ]]; then
    WORKLOADS=(cpu memory pgbench)
  fi

  for workload in "${WORKLOADS[@]}"; do
    case "$workload" in
      cpu) run_cpu_benchmark ;;
      memory) run_memory_benchmark ;;
      pgbench) run_pgbench ;;
      *) log "Unknown workload: $workload" ;;
    esac
  done

  collect_metrics
  upload_logs "$BUCKET_NAME"
  log "All workloads complete."
}

main "$@"
