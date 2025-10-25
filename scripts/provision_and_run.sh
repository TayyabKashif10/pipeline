#!/bin/bash
set -euo pipefail
OUT_DIR=${1:-/workspace}
PROJECT=$(gcloud config get-value project)
REGION=us-central1
ZONE=us-central1-a
BUCKET="${PROJECT}-storage"
RESULTS_DIR="results/$(date +%Y%m%d_%H%M%S)"
mkdir -p $RESULTS_DIR

# List of machine types to test (update as needed)
MACHINES=(
  "e2-standard-4"
  "n2-standard-4"
  "c2-standard-4"
  "m1-ultramem-2"
  "e2-standard-4-preemptible"
)

# If preemptible, mark it specially in VM name
instance_prefix="bench"
network="default"

# common image
IMAGE_FAMILY="ubuntu-2204-lts"
IMAGE_PROJECT="ubuntu-os-cloud"

# workload parameters (example: pgbench or sysbench)
WORKLOAD="sysbench"   # options: sysbench or pgbench
WORKLOAD_RUN_TIME=300 # seconds per run (5 minutes)
WARMUP_TIME=60

for machine in "${MACHINES[@]}"; do
  # map preemptible naming
  PREEMPT=false
  machine_name="$machine"
  if [[ "$machine" == *"preemptible"* ]]; then
    PREEMPT=true
    machine_type="${machine%-preemptible}"
    machine_label="${machine_type//./-}-preempt"
  else
    machine_type="$machine"
    machine_label="${machine_type//./-}"
  fi

  # craft instance name safe
  inst_name="${instance_prefix}-${machine_label}-$(date +%s)"

  echo "Creating instance: $inst_name type=$machine_type preemptible=$PREEMPT"
  if [ "$PREEMPT" = true ]; then
    gcloud compute instances create $inst_name \
      --project=$PROJECT --zone=$ZONE \
      --machine-type=$machine_type \
      --image-family=$IMAGE_FAMILY --image-project=$IMAGE_PROJECT \
      --metadata=startup-script-url=gs://$BUCKET/startup-scripts/workload_runner.sh \
      --preemptible \
      --scopes=https://www.googleapis.com/auth/cloud-platform
  else
    gcloud compute instances create $inst_name \
      --project=$PROJECT --zone=$ZONE \
      --machine-type=$machine_type \
      --image-family=$IMAGE_FAMILY --image-project=$IMAGE_PROJECT \
      --metadata=startup-script-url=gs://$BUCKET/startup-scripts/workload_runner.sh \
      --scopes=https://www.googleapis.com/auth/cloud-platform
  fi

  # Wait for SSH readiness
  echo "Waiting for SSH on $inst_name..."
  gcloud compute ssh $inst_name --zone=$ZONE --command="echo ready" || true

  # Copy workload_runner to instance and run remote command to kick off workload.
  gcloud compute scp scripts/workload_runner.sh $inst_name:~/ --zone=$ZONE
  gcloud compute ssh $inst_name --zone=$ZONE --command="chmod +x ~/workload_runner.sh && sudo ~/workload_runner.sh $WORKLOAD $WARMUP_TIME $WORKLOAD_RUN_TIME gs://$BUCKET/results/$inst_name" &

  # Short sleep between creations to avoid rate limits
  sleep 5
done

echo "All instances created and workloads started. Waiting for completion..."
# Wait heuristic: sleep total run time + buffer (you could poll for output in bucket)
sleep $((WARMUP_TIME + WORKLOAD_RUN_TIME + 120))

# Copy bucket results to local results dir for analysis
mkdir -p $RESULTS_DIR
gsutil -m cp -r gs://$BUCKET/results/* $RESULTS_DIR/ || true
echo "Results copied to $RESULTS_DIR"

# create a small manifest for the run
cat > $RESULTS_DIR/manifest.txt <<EOF
project: $PROJECT
zone: $ZONE
machines: ${MACHINES[*]}
workload: $WORKLOAD
workload_run_time: $WORKLOAD_RUN_TIME
date: $(date -u)
EOF

# move results into workspace so Cloud Build step can upload
mv $RESULTS_DIR /workspace/results || true
