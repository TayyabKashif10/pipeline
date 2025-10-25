#!/bin/bash
set -euo pipefail

OUT_DIR=${1:-/workspace}
PROJECT=$(gcloud config get-value project)
REGION=us-central1
ZONE=us-central1-a
BUCKET="${PROJECT}-storage"

# Machine types to test
MACHINES=(
  "e2-standard-4"
#   "n2-standard-4"
#   "c2-standard-4"
#   "c4-standard-2"
#   "e2-highmem-4"
)

IMAGE_FAMILY="ubuntu-2204-lts"
IMAGE_PROJECT="ubuntu-os-cloud"
WORKLOAD="all"
WORKLOAD_RUN_TIME=300   # seconds
WARMUP_TIME=60

# Helper: wait for SSH readiness
wait_for_ssh() {
  local instance=$1
  echo "⏳ Waiting for SSH on $instance..."
  for i in {1..30}; do
    if gcloud compute ssh "$instance" --zone="$ZONE" --command="echo ready" &>/dev/null; then
      echo "✅ SSH ready for $instance"
      return 0
    fi
    sleep 10
  done
  echo "❌ ERROR: SSH never became ready for $instance"
  return 1
}

# Helper: teardown instance safely
teardown_instance() {
  local instance=$1
  echo "🧹 Tearing down instance $instance..."
  gcloud compute instances delete "$instance" --zone="$ZONE" --quiet || echo "⚠️ Failed to delete $instance"
}

# Sequential benchmarking loop
for machine in "${MACHINES[@]}"; do
  echo "=============================================================="
  echo "🏁 Starting benchmark for machine type: $machine"
  echo "=============================================================="

  PREEMPT=false
  if [[ "$machine" == *"preemptible"* ]]; then
    PREEMPT=true
    machine_type="${machine%-preemptible}"
    machine_label="${machine_type//./-}-preempt"
  else
    machine_type="$machine"
    machine_label="${machine_type//./-}"
  fi

  inst_name="bench-${machine_label}-$(date +%s)"

  echo "🚀 Creating instance: $inst_name (type=$machine_type, preemptible=$PREEMPT)"
  if [ "$PREEMPT" = true ]; then
    gcloud compute instances create "$inst_name" \
      --project="$PROJECT" --zone="$ZONE" \
      --machine-type="$machine_type" \
      --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
      --metadata=startup-script-url=gs://$BUCKET/startup-scripts/workload_runner.sh \
      --preemptible \
      --scopes=https://www.googleapis.com/auth/cloud-platform
  else
    gcloud compute instances create "$inst_name" \
      --project="$PROJECT" --zone="$ZONE" \
      --machine-type="$machine_type" \
      --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
      --metadata=startup-script-url=gs://$BUCKET/startup-scripts/workload_runner.sh \
      --scopes=https://www.googleapis.com/auth/cloud-platform
  fi

  # Wait for SSH availability
  wait_for_ssh "$inst_name" || { teardown_instance "$inst_name"; continue; }

  echo "📤 Copying workload_runner.sh to $inst_name..."
  gcloud compute scp scripts/workload_runner.sh "$inst_name:~/workload_runner.sh" --zone="$ZONE"

  echo "⚙️  Running workload on $inst_name..."
  if ! gcloud compute ssh "$inst_name" --zone="$ZONE" \
    --command="chmod +x ~/workload_runner.sh && sudo ~/workload_runner.sh $WORKLOAD $WARMUP_TIME $WORKLOAD_RUN_TIME gs://$BUCKET/results/$inst_name"; then
    echo "⚠️ Workload failed on $inst_name"
  fi

  # Cleanup
  teardown_instance "$inst_name"

  echo "✅ Finished $machine benchmark."
  echo
done


echo "📦 All benchmarks complete."
