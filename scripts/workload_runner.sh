#!/bin/bash
set -euo pipefail
WORKLOAD=${1:-sysbench}
WARMUP=${2:-60}
RUN_TIME=${3:-300}
GCS_OUT=${4:-}

OUTDIR="/tmp/bench-$(date +%s)"
mkdir -p $OUTDIR

# install tools
sudo apt-get update -y
sudo apt-get install -y sysbench jq curl git build-essential

# Optionally install pgbench if required (postgres client)
sudo apt-get install -y postgresql-client

# Run depending on workload
if [ "$WORKLOAD" = "sysbench" ]; then
  # CPU benchmark example (tune params)
  sysbench cpu --threads=4 --time=$WARMUP run > $OUTDIR/sysbench_warmup.txt || true
  sysbench cpu --threads=4 --time=$RUN_TIME run > $OUTDIR/sysbench_run.txt || true

  # Collect top/dstat output (if installed)
  # you could install dstat/collectl here to gather system metrics
fi

if [ -n "$GCS_OUT" ]; then
  # ensure bucket path exists
  gsutil -m cp -r $OUTDIR $GCS_OUT || true
fi

echo "Workload finished, output pushed to $GCS_OUT"
