#!/bin/bash
set -euo pipefail
PROJECT=$(gcloud config get-value project)
ZONE=us-central1-a
# Delete instances created with prefix 'bench-'
for i in $(gcloud compute instances list --zones=$ZONE --filter="name~'^bench-'" --format="value(name)"); do
  gcloud compute instances delete $i --zone=$ZONE --quiet || true
done

# delete instance templates
for t in $(gcloud compute instance-templates list --filter="name~'bench-template'" --format="value(name)"); do
  gcloud compute instance-templates delete $t --quiet || true
done

# delete MIGs
for g in $(gcloud compute instance-groups managed list --zones=$ZONE --filter="name~'bench-mig'" --format="value(name)"); do
  gcloud compute instance-groups managed delete $g --zone=$ZONE --quiet || true
done

# Optionally delete the bucket (uncomment if you want to delete)
# gsutil rm -r gs://$PROJECT-benchmark-artifacts

echo "Teardown complete."
