# GCP Benchmark Pipeline - README

Pre-reqs:
- gcloud CLI configured with your project
- Cloud Build API enabled
- Cloud Build service account has required IAM roles
- Create a GCS bucket: gs://<PROJECT>-storage

Steps:
1. Set PROJECT and BUCKET env vars:
   export PROJECT=your-project-id
   export BUCKET=${PROJECT}-storage

2. Trigger Cloud Build:
   gcloud builds submit --config cloudbuild.yaml . --substitutions=_BUCKET=$BUCKET

3. Wait for Cloud Build completion. Results and analysis will be in gs://$BUCKET/results/

4. Capture billing screenshots:
   - Billing BEFORE: save to results/screenshots/billing_before.png
   - Billing AFTER: save to results/screenshots/billing_after.png

5. Cleanup: Cloud Build will run teardown.sh automatically, but verify no instances remain:
   gcloud compute instances list

