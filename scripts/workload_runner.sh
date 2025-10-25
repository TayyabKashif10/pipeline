#!/bin/bash
set -euo pipefail

# === CONFIG ===
WORKLOAD=${1:-sysbench}
WARMUP=${2:-60}
RUN_TIME=${3:-300}
GCS_OUT=${4:-}
OUTDIR="/tmp/bench-$(date +%s)"
mkdir -p "$OUTDIR"

echo "=== Starting workload runner ==="
echo "Workload: $WORKLOAD"
echo "Warmup time: ${WARMUP}s"
echo "Run time: ${RUN_TIME}s"
echo "Output directory: $OUTDIR"
echo "GCS output path: ${GCS_OUT:-<none>}"

# === HELPER: retry wrapper ===
retry() {
  local n=0
  local try=$1
  shift
  until [ "$n" -ge "$try" ]; do
    "$@" && break
    n=$((n+1))
    echo "Attempt $n/$try failed. Retrying in 5s..."
    sleep 5
  done
  [ "$n" -lt "$try" ]
}

# === HELPER: wait for apt lock ===
wait_for_apt() {
  echo "⏳ Waiting for apt/dpkg locks to clear..."
  while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
        sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
        sudo fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
    sleep 5
  done
  echo "✅ Apt locks cleared."
}

# === INSTALL DEPENDENCIES ===
wait_for_apt
retry 3 sudo apt-get update -y
retry 3 sudo apt-get install -y jq curl git build-essential sysbench || {
  echo "⚠️ Sysbench package not found; building from source."
  git clone https://github.com/akopytov/sysbench.git /tmp/sysbench-src
  cd /tmp/sysbench-src
  ./autogen.sh && ./configure && make -j"$(nproc)" && sudo make install
  cd - && rm -rf /tmp/sysbench-src
}

# === VERIFY gsutil ===
if ! command -v gsutil &>/dev/null; then
  echo "⚠️ gsutil not found, installing minimal Cloud SDK..."
  curl -sSL https://sdk.cloud.google.com | bash >/dev/null 2>&1 || echo "⚠️ Cloud SDK install failed."
  source "$HOME/google-cloud-sdk/path.bash.inc" || true
fi

# === RUN WORKLOAD ===
if [ "$WORKLOAD" = "sysbench" ]; then
  echo "▶ Running sysbench CPU test..."
  sysbench cpu --threads=4 --time="$WARMUP" run > "$OUTDIR/sysbench_warmup.txt" || true
  sysbench cpu --threads=4 --time="$RUN_TIME" run > "$OUTDIR/sysbench_run.txt" || true
else
  echo "❌ Unsupported workload: $WORKLOAD"
  exit 1
fi

# === UPLOAD RESULTS ===
if [ -n "$GCS_OUT" ]; then
  echo "☁️ Uploading results to $GCS_OUT..."
  if command -v gsutil &>/dev/null; then
    retry 3 gsutil -m cp -r "$OUTDIR" "$GCS_OUT" || echo "⚠️ Upload failed after retries."
  else
    echo "⚠️ gsutil unavailable; skipping upload."
  fi
else
  echo "ℹ️ No GCS output path provided; results remain local at $OUTDIR"
fi

echo "✅ Workload finished successfully."
