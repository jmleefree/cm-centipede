# ---------------------------------------------------------------------------
# Cloud Storage bucket, used as the object storage migration test target.
#   gendata fills it through the S3-compatible XML API (storage.googleapis.com)
#   with the HMAC key GCP_S3_ACCESS_KEY / GCP_S3_SECRET_KEY, the cb-tumblebug /
#   cb-spider S3AccessKey / S3SecretKey. The HMAC key is NOT created here: it
#   must already exist, for a service account allowed to write the bucket - the
#   one in secret/csp/gcp is, through its project role.
#   force_destroy deletes whatever gendata put in the bucket on teardown.
# ---------------------------------------------------------------------------
resource "google_storage_bucket" "this" {
  name          = var.gcp_bucket_name
  location      = upper(var.gcp_region)
  storage_class = "STANDARD"
  force_destroy = true

  # Access by IAM only, no per-object ACLs, and never public.
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # Soft delete is on for new buckets by default (7 days): every object gendata
  # --cleanup or force_destroy removes would be kept - and billed - that long.
  # A test bucket has nothing to recover, so it is off.
  soft_delete_policy {
    retention_duration_seconds = 0
  }

  labels = {
    name_prefix = var.gcp_name_prefix
  }
}
