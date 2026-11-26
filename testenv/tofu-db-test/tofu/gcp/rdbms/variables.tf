variable "gcp_project_id" {
  description = "Project the provider works in (GCP_PROJECT_ID). Not passed by the matrix: scripts/lib/csp-env.sh exports it as TF_VAR_gcp_project_id from OpenBao (secret/csp/gcp)"
  type        = string

  validation {
    condition     = var.gcp_project_id != ""
    error_message = "gcp_project_id is empty: GCP_PROJECT_ID is not registered in OpenBao (secret/csp/gcp). Set it in .env and run ./scripts/up.sh."
  }
}

variable "gcp_region" {
  description = "GCP region, e.g. asia-northeast3 (Seoul)"
  type        = string
  default     = "asia-northeast3"
}

variable "name_prefix" {
  description = "Resource name prefix; starts the instance name"
  type        = string
  default     = "cptfm"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,5}$", var.name_prefix))
    error_message = "Prefix must be 2-6 characters of lowercase letters and digits, starting with a letter (MATRIX_NAME_PREFIX)."
  }
}

# One column of the matrix = one instance. These two are what changes between
# applies; each pair gets its own tofu workspace.
variable "engine" {
  description = "Managed engine: mysql or postgresql. GCP has no managed MariaDB or MongoDB"
  type        = string

  validation {
    condition     = contains(["mysql", "postgresql"], var.engine)
    error_message = "engine must be mysql or postgresql. GCP has no managed MariaDB or MongoDB."
  }
}

variable "engine_version" {
  description = "Version number alone: MySQL 8.0 / 8.4, PostgreSQL a major (16). Turned into MYSQL_8_4 / POSTGRES_16"
  type        = string

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+){0,2}$", var.engine_version))
    error_message = "Expected a version like 8.4 or 16. Run ./scripts/gcp-db-versions.sh to list what Cloud SQL offers."
  }
}

variable "db_name" {
  description = "Admin database created with the instance; the matrix connects to it to create and drop each cell's target database"
  type        = string
  default     = "matrixadm"
}

variable "db_username" {
  description = "Admin account, a member of cloudsqlsuperuser"
  type        = string
  default     = "dbadmin"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,31}$", var.db_username))
    error_message = "db_username must be lowercase letters, digits and underscores starting with a letter, 32 characters at most."
  }
}

variable "allowed_cidr" {
  description = "CIDR allowed as the instance's authorized network; the matrix host has to be inside it"
  type        = string
  default     = "0.0.0.0/0"
}

variable "tier" {
  description = "Machine tier: db-custom-<vCPU>-<memory MB> (1 vCPU / 3.75 GB by default) or a predefined one"
  type        = string
  default     = "db-custom-1-3840"
}

variable "storage_gb" {
  description = "Storage in GB (10 or more)"
  type        = number
  default     = 20

  validation {
    condition     = var.storage_gb >= 10
    error_message = "storage_gb must be 10 or more."
  }
}
