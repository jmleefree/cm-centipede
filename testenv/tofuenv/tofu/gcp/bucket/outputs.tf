output "bucket_name" {
  description = "Name of the created bucket (gendata uses it as the upload target)"
  value       = google_storage_bucket.this.name
}

output "bucket_region" {
  description = "Region of the bucket, as the S3-compatible API signs with it"
  value       = lower(google_storage_bucket.this.location)
}

output "bucket_url" {
  value = google_storage_bucket.this.url
}

output "s3_endpoint" {
  description = "S3-compatible XML API endpoint, used with the HMAC key (GCP_S3_ACCESS_KEY / GCP_S3_SECRET_KEY)"
  value       = "storage.googleapis.com"
}

output "project_id" {
  description = "Project the bucket is in (GCP_PROJECT_ID)"
  value       = var.gcp_project_id
}

output "name_prefix" {
  description = "Name prefix, and the tofu workspace this environment lives in"
  value       = var.gcp_name_prefix
}
