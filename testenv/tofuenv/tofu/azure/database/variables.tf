variable "azure_region" {
  description = "Azure region (what Azure calls the location), e.g. koreacentral"
  type        = string
  default     = "koreacentral"
}

variable "azure_name_prefix" {
  description = "Resource name prefix, short for centipede tofu. Names the resource group (<prefix>-database-rg) and the servers in it"
  type        = string
  default     = "cptf"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,11}$", var.azure_name_prefix))
    error_message = "Prefix must be 2-12 characters of lowercase letters, digits and hyphens, starting with a lowercase letter."
  }
}

variable "allowed_cidr" {
  description = "CIDR allowed through the server firewalls; turned into the start/end IP range Azure takes. Wide open by default"
  type        = string
  default     = "0.0.0.0/0"
}

variable "azure_db_name" {
  description = "Initial database name, created on mysql and postgresql"
  type        = string
  default     = "testdb"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.azure_db_name))
    error_message = "azure_db_name must start with a lowercase letter and hold lowercase letters, digits and underscores, 63 characters at most."
  }
}

variable "azure_db_username" {
  description = "Admin account on all three engines"
  type        = string
  default     = "dbadmin"

  validation {
    condition = (
      can(regex("^[a-z][a-z0-9_]{0,62}$", var.azure_db_username))
      && !contains(["admin", "administrator", "root", "azure_superuser", "azure_pg_admin", "guest", "public", "sa"], var.azure_db_username)
      && !startswith(var.azure_db_username, "pg_")
    )
    error_message = "azure_db_username must be lowercase letters, digits and underscores starting with a letter, and not one Azure reserves (admin, administrator, root, azure_superuser, azure_pg_admin, guest, public, sa, pg_*)."
  }
}

# Which engines this module runs. Not set in .env: prepare.sh and teardown.sh
# work it out from --engine and from what the state already holds, and export it
# for each apply. The default - every engine - is what a plain apply gets.
variable "azure_db_engines" {
  description = "Engines to run: any of mysql, postgres, mongodb"
  type        = list(string)
  default     = ["mysql", "postgres", "mongodb"]

  validation {
    condition     = alltrue([for e in var.azure_db_engines : contains(["mysql", "postgres", "mongodb"], e)])
    error_message = "azure_db_engines may only contain mysql, postgres and mongodb."
  }
}

# ---------------------------------------------------------------------------
# MySQL / PostgreSQL Flexible Server
#   List the SKUs with ./scripts/azure-db-versions.sh <mysql|postgresql>
# ---------------------------------------------------------------------------
variable "azure_mysql_sku" {
  description = "MySQL Flexible Server SKU, <tier>_<size>, e.g. B_Standard_B1ms"
  type        = string
  default     = "B_Standard_B1ms"
}

variable "azure_mysql_storage_gb" {
  description = "MySQL storage in GB (20-16384)"
  type        = number
  default     = 20

  validation {
    condition     = var.azure_mysql_storage_gb >= 20 && var.azure_mysql_storage_gb <= 16384
    error_message = "azure_mysql_storage_gb must be 20-16384."
  }
}

variable "azure_postgres_sku" {
  description = "PostgreSQL Flexible Server SKU, <tier>_<size>, e.g. B_Standard_B1ms"
  type        = string
  default     = "B_Standard_B1ms"
}

variable "azure_postgres_storage_gb" {
  description = "PostgreSQL storage in GB; one of the fixed sizes Azure sells"
  type        = number
  default     = 32

  validation {
    condition     = contains([32, 64, 128, 256, 512, 1024, 2048, 4095, 4096, 8192, 16384, 32767], var.azure_postgres_storage_gb)
    error_message = "azure_postgres_storage_gb must be one of 32, 64, 128, 256, 512, 1024, 2048, 4095, 4096, 8192, 16384, 32767."
  }
}

variable "azure_mysql_version" {
  description = "MySQL Flexible Server version: 5.7, 8.0.21 or 8.4"
  type        = string
  default     = "8.0.21"
}

variable "azure_postgres_version" {
  description = "PostgreSQL Flexible Server major version, e.g. 14"
  type        = string
  default     = "14"
}

# ---------------------------------------------------------------------------
# Cosmos DB for MongoDB vCore
# ---------------------------------------------------------------------------
variable "azure_mongodb_version" {
  description = "MongoDB vCore version: 5.0, 6.0, 7.0 or 8.0"
  type        = string
  default     = "7.0"
}

# M30 (2 vCore / 8 GB) is the smallest non-burstable tier. A cluster at M30 or
# above cannot be scaled back down to the burstable M10 / M20 / M25.
variable "azure_mongodb_tier" {
  description = "MongoDB vCore compute tier: Free (one per subscription), M10, M20, M25 (burstable), M30, M40, ..."
  type        = string
  default     = "M30"
}

variable "azure_mongodb_storage_gb" {
  description = "MongoDB vCore storage in GB"
  type        = number
  default     = 32
}

variable "azure_mongodb_high_availability" {
  description = "MongoDB vCore high availability: Disabled or ZoneRedundantPreferred"
  type        = string
  default     = "Disabled"

  validation {
    condition     = contains(["Disabled", "ZoneRedundantPreferred"], var.azure_mongodb_high_availability)
    error_message = "azure_mongodb_high_availability must be Disabled or ZoneRedundantPreferred."
  }
}
