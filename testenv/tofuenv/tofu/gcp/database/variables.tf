variable "gcp_region" {
  description = "GCP region, e.g. asia-northeast3 (Seoul). The Cloud SQL instances are created there"
  type        = string
  default     = "asia-northeast3"
}

variable "gcp_name_prefix" {
  description = "Resource name prefix, short for centipede tofu. Starts the Cloud SQL instance names"
  type        = string
  default     = "cptf"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,11}$", var.gcp_name_prefix))
    error_message = "Prefix must be 2-12 characters of lowercase letters, digits and hyphens, starting with a lowercase letter."
  }
}

variable "allowed_cidr" {
  description = "CIDR allowed as the instances' authorized network; wide open by default"
  type        = string
  default     = "0.0.0.0/0"
}

variable "gcp_db_name" {
  description = "Initial database name, created on mysql and postgresql"
  type        = string
  default     = "testdb"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.gcp_db_name))
    error_message = "gcp_db_name must start with a lowercase letter and hold lowercase letters, digits and underscores, 63 characters at most."
  }
}

variable "gcp_db_username" {
  description = "Admin account on both engines"
  type        = string
  default     = "dbadmin"

  validation {
    condition = (
      can(regex("^[a-z][a-z0-9_]{0,31}$", var.gcp_db_username))
      && !contains(["root", "postgres", "cloudsqlsuperuser", "cloudsqladmin", "cloudsqlagent", "cloudsqlreplica", "cloudsqlimport", "cloudsqlexport", "cloudsqliamuser", "cloudsqliamserviceaccount", "mysql"], var.gcp_db_username)
      && !startswith(var.gcp_db_username, "pg_")
      && !startswith(var.gcp_db_username, "cloudsql")
    )
    error_message = "gcp_db_username must be lowercase letters, digits and underscores starting with a letter, 32 characters at most, and not one Cloud SQL keeps for itself (root, postgres, mysql, cloudsql*, pg_*)."
  }
}

# Which engines this module runs. Not set in .env: prepare.sh and teardown.sh
# work it out from --engine and from what the state already holds, and export it
# for each apply. The default - every engine - is what a plain apply gets.
variable "gcp_db_engines" {
  description = "Engines to run: any of mysql, postgres"
  type        = list(string)
  default     = ["mysql", "postgres"]

  validation {
    condition     = alltrue([for e in var.gcp_db_engines : contains(["mysql", "postgres"], e)])
    error_message = "gcp_db_engines may only contain mysql and postgres."
  }
}

# ---------------------------------------------------------------------------
# Cloud SQL sizing
#   List the tiers with ./scripts/gcp-db-versions.sh <mysql|postgresql>
# ---------------------------------------------------------------------------
variable "gcp_mysql_tier" {
  description = "Cloud SQL for MySQL tier, e.g. db-custom-1-3840 (1 vCPU / 3.75 GB) or the shared-core db-g1-small"
  type        = string
  default     = "db-custom-1-3840"
}

variable "gcp_mysql_storage_gb" {
  description = "MySQL storage in GB (10 or more); it does not grow by itself"
  type        = number
  default     = 20

  validation {
    condition     = var.gcp_mysql_storage_gb >= 10 && floor(var.gcp_mysql_storage_gb) == var.gcp_mysql_storage_gb
    error_message = "gcp_mysql_storage_gb must be a whole number of GB, 10 or more."
  }
}

variable "gcp_postgres_tier" {
  description = "Cloud SQL for PostgreSQL tier, e.g. db-custom-1-3840 (1 vCPU / 3.75 GB) or the shared-core db-g1-small"
  type        = string
  default     = "db-custom-1-3840"
}

variable "gcp_postgres_storage_gb" {
  description = "PostgreSQL storage in GB (10 or more); it does not grow by itself"
  type        = number
  default     = 20

  validation {
    condition     = var.gcp_postgres_storage_gb >= 10 && floor(var.gcp_postgres_storage_gb) == var.gcp_postgres_storage_gb
    error_message = "gcp_postgres_storage_gb must be a whole number of GB, 10 or more."
  }
}

# The version number alone; main.tf turns it into the Cloud SQL name.
variable "gcp_mysql_version" {
  description = "Cloud SQL for MySQL version, e.g. 8.4 (becomes MYSQL_8_4)"
  type        = string
  default     = "8.4"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.gcp_mysql_version))
    error_message = "gcp_mysql_version must be the version number alone, e.g. 8.4 or 8.0 - not MYSQL_8_4."
  }
}

variable "gcp_postgres_version" {
  description = "Cloud SQL for PostgreSQL major version, e.g. 16 (becomes POSTGRES_16)"
  type        = string
  default     = "16"

  validation {
    condition     = can(regex("^[0-9]+$", var.gcp_postgres_version))
    error_message = "gcp_postgres_version must be the major version number alone, e.g. 16 - not POSTGRES_16."
  }
}
