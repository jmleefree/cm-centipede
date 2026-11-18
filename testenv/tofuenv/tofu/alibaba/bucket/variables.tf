variable "alibaba_region" {
  description = "Alibaba Cloud region ID"
  type        = string
  default     = "ap-northeast-2"
}

variable "alibaba_bucket_name" {
  description = "OSS bucket name: globally unique, 3-63 chars of lowercase letters, digits and hyphens, starting and ending with a letter or digit"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.alibaba_bucket_name))
    error_message = "Bucket name must be 3-63 characters of lowercase letters, digits and hyphens, and start and end with a letter or digit."
  }
}

variable "alibaba_name_prefix" {
  description = "Resource name prefix, short for centipede tofu. The bucket name does not use it (it is set in full); it names the environment this bucket belongs to"
  type        = string
  default     = "cptf"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,19}$", var.alibaba_name_prefix))
    error_message = "Prefix must be 2-20 characters of lowercase letters, digits and hyphens, starting with a lowercase letter."
  }
}
