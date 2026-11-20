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
