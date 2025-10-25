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

2. Upload startup scripts to the bucket:
   gsutil cp scripts/workload_runner.sh gs://$BUCKET/startup-scripts/

3. Trigger Cloud Build:
   gcloud builds submit --config cloudbuild.yaml . --substitutions=_BUCKET=$BUCKET

4. Wait for Cloud Build completion. Results and analysis will be in gs://$BUCKET/results/

5. Capture billing screenshots:
   - Billing BEFORE: save to results/screenshots/billing_before.png
   - Billing AFTER: save to results/screenshots/billing_after.png

6. Cleanup: Cloud Build will run teardown.sh automatically, but verify no instances remain:
   gcloud compute instances list

