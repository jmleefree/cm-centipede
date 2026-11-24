variable "azure_bucket_name" {
  description = "Blob container name, created in the existing storage account (AZURE_S3_ACCESS_KEY): 3-63 chars of lowercase letters, digits and hyphens, starting with a letter or digit, no consecutive hyphens"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.azure_bucket_name)) && !can(regex("--", var.azure_bucket_name))
    error_message = "Container name must be 3-63 characters of lowercase letters, digits and hyphens, start and end with a letter or digit, and contain no consecutive hyphens."
  }
}

variable "azure_name_prefix" {
  description = "Resource name prefix, short for centipede tofu. The container name does not use it (it is set in full); it names the environment this bucket belongs to"
  type        = string
  default     = "cptf"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,11}$", var.azure_name_prefix))
    error_message = "Prefix must be 2-12 characters of lowercase letters, digits and hyphens, starting with a lowercase letter."
  }
}

variable "azure_storage_account_name" {
  description = "Name of the existing storage account the container goes in (AZURE_S3_ACCESS_KEY). Not set in .env: scripts/lib/csp-env.sh exports it as TF_VAR_azure_storage_account_name from OpenBao (secret/csp/azure)"
  type        = string

  validation {
    condition     = var.azure_storage_account_name != ""
    error_message = "azure_storage_account_name is empty: AZURE_S3_ACCESS_KEY is not registered in OpenBao (secret/csp/azure). Set it in .env and run ./scripts/up.sh."
  }
}
