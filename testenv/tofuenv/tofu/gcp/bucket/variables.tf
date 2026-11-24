variable "gcp_region" {
  description = "GCP region, e.g. asia-northeast3 (Seoul). The bucket is a regional one there"
  type        = string
  default     = "asia-northeast3"
}

variable "gcp_bucket_name" {
  description = "Bucket name, global across all of Google Cloud: 3-63 chars of lowercase letters, digits, hyphens, underscores and dots, starting and ending with a letter or digit"
  type        = string

  validation {
    condition = (
      can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.gcp_bucket_name))
      && !startswith(var.gcp_bucket_name, "goog")
      && !can(regex("google|g00gle", var.gcp_bucket_name))
    )
    error_message = "Bucket name must be 3-63 characters of lowercase letters, digits, hyphens, underscores and dots, start and end with a letter or digit, not start with goog and not contain google."
  }
}

variable "gcp_name_prefix" {
  description = "Resource name prefix, short for centipede tofu. The bucket name does not use it (it is set in full); it labels the bucket with the environment it belongs to"
  type        = string
  default     = "cptf"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,11}$", var.gcp_name_prefix))
    error_message = "Prefix must be 2-12 characters of lowercase letters, digits and hyphens, starting with a lowercase letter."
  }
}

variable "gcp_project_id" {
  description = "Project the provider works in (GCP_PROJECT_ID). Not set in .env: scripts/lib/csp-env.sh exports it as TF_VAR_gcp_project_id from OpenBao (secret/csp/gcp)"
  type        = string

  validation {
    condition     = var.gcp_project_id != ""
    error_message = "gcp_project_id is empty: GCP_PROJECT_ID is not registered in OpenBao (secret/csp/gcp). Set it in .env and run ./scripts/up.sh."
  }
}
