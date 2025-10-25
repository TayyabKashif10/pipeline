Pre-reqs:
- Cloud Compute API enabled
- Cloud Build API enabled
- Cloud Build service account has required IAM roles
- Create a GCS bucket: gs://<PROJECT>-storage

Steps:
1. Set BUCKET env variable

2: Make sure you're in pipeline directory.

2. Trigger Cloud Build:
   gcloud builds submit --config cloudbuild.yaml . --substitutions=_BUCKET=$BUCKET

3. Wait for Cloud Build completion. Results and analysis will be in gs://$BUCKET/results/
