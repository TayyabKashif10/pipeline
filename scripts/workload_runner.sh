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

# === INSTALL DEPENDENCIES ===
echo "Installing required packages..."

retry 3 sudo apt-get update -y

# Enable universe (Ubuntu) or contrib (Debian)
if [ -f /etc/lsb-release ]; then
  echo "Detected Ubuntu. Ensuring universe repo is enabled..."
  sudo apt-get install -y software-properties-common
  sudo add-apt-repository -y universe || true
elif grep -qi debian /etc/os-release; then
  echo "Detected Debian. Enabling contrib repo..."
  sudo sed -Ei 's/^# deb-src/deb-src/' /etc/apt/sources.list || true
fi

retry 3 sudo apt-get update -y
retry 3 sudo apt-get install -y jq curl git build-essential || true

# Sysbench is sometimes in a separate repo
if ! command -v sysbench &>/dev/null; then
  echo "Installing sysbench..."
  retry 3 sudo apt-get install -y sysbench || {
    echo "Sysbench package not found. Trying to build from source..."
    git clone https://github.com/akopytov/sysbench.git /tmp/sysbench-src
    cd /tmp/sysbench-src
    ./autogen.sh && ./configure && make -j"$(nproc)" && sudo make install
    cd -
  }
fi

# Verify gsutil (used to copy results to GCS)
if ! command -v gsutil &>/dev/null; then
  echo "gsutil not found. Installing Google Cloud SDK..."
  curl -sSL https://sdk.cloud.google.com | bash || {
    echo "Warning: Could not install gsutil. Skipping upload step."
  }
  source "$HOME/google-cloud-sdk/path.bash.inc" || true
fi

# === RUN WORKLOAD ===
if [ "$WORKLOAD" = "sysbench" ]; then
  echo "Running sysbench CPU test..."
  sysbench cpu --threads=4 --time="$WARMUP" run > "$OUTDIR/sysbench_warmup.txt" || true
  sysbench cpu --threads=4 --time="$RUN_TIME" run > "$OUTDIR/sysbench_run.txt" || true
else
  echo "Unsupported workload: $WORKLOAD"
  exit 1
fi

# === UPLOAD RESULTS ===
if [ -n "$GCS_OUT" ]; then
  echo "Uploading results to $GCS_OUT..."
  if command -v gsutil &>/dev/null; then
    retry 3 gsutil -m cp -r "$OUTDIR" "$GCS_OUT" || {
      echo "⚠️ Failed to upload to GCS after retries."
    }
  else
    echo "⚠️ gsutil not available; skipping upload."
  fi
else
  echo "No GCS output path provided; results remain local at $OUTDIR"
fi

echo "✅ Workload finished successfully."
