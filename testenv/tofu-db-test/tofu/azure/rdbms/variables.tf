variable "azure_region" {
  description = "Azure region (what Azure calls the location), e.g. koreacentral"
  type        = string
  default     = "koreacentral"
}

variable "name_prefix" {
  description = "Resource name prefix; starts the resource group and server names"
  type        = string
  default     = "cptfm"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,5}$", var.name_prefix))
    error_message = "Prefix must be 2-6 characters of lowercase letters and digits, starting with a letter (MATRIX_NAME_PREFIX)."
  }
}

# One column of the matrix = one server. These two are what changes between
# applies; each pair gets its own tofu workspace.
variable "engine" {
  description = "Managed engine: mysql, postgresql or mongodb. Azure Database for MariaDB was retired"
  type        = string

  validation {
    condition     = contains(["mysql", "postgresql", "mongodb"], var.engine)
    error_message = "engine must be one of mysql, postgresql, mongodb. Azure Database for MariaDB was retired on 2025-09-19."
  }
}

# MySQL 5.7 / 8.0.21 / 8.4, PostgreSQL a major (14), MongoDB 5.0-8.0.
variable "engine_version" {
  description = "Engine version as Azure takes it: MySQL 8.0.21 or 8.4, PostgreSQL 14, MongoDB 7.0"
  type        = string

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+){0,2}$", var.engine_version))
    error_message = "Expected a version like 8.0.21, 14 or 7.0. Run ./scripts/azure-db-versions.sh to list what the region sells."
  }
}

variable "db_name" {
  description = "Admin database created with a MySQL or PostgreSQL server; the matrix connects to it to create and drop each cell's target database. Not used for MongoDB"
  type        = string
  default     = "matrixadm"
}

variable "db_username" {
  description = "Admin account"
  type        = string
  default     = "dbadmin"

  validation {
    condition = (
      can(regex("^[a-z][a-z0-9_]{0,62}$", var.db_username))
      && !contains(["admin", "administrator", "root", "azure_superuser", "azure_pg_admin", "guest", "public", "sa"], var.db_username)
      && !startswith(var.db_username, "pg_")
    )
    error_message = "db_username must be lowercase letters, digits and underscores starting with a letter, and not one Azure reserves (admin, administrator, root, azure_superuser, azure_pg_admin, guest, public, sa, pg_*)."
  }
}

variable "allowed_cidr" {
  description = "CIDR allowed through the server firewall; turned into the start/end IP range Azure takes"
  type        = string
  default     = "0.0.0.0/0"
}

variable "sku" {
  description = "Flexible Server SKU, <tier>_<size>. MySQL and PostgreSQL only. Empty: B_Standard_B2s for MySQL, GP_Standard_D2ds_v5 for PostgreSQL"
  type        = string
  default     = ""
}

variable "storage_gb" {
  description = "Storage in GB. MySQL 20-16384; PostgreSQL one of the fixed sizes (32, 64, 128, ...); MongoDB vCore any size its tier allows"
  type        = number
  default     = 32
}

variable "mongodb_tier" {
  description = "MongoDB vCore compute tier: M10, M20, M25 (burstable), M30, M40, ..."
  type        = string
  default     = "M30"
}

variable "mongodb_high_availability" {
  description = "MongoDB vCore high availability: Disabled or ZoneRedundantPreferred"
  type        = string
  default     = "Disabled"

  validation {
    condition     = contains(["Disabled", "ZoneRedundantPreferred"], var.mongodb_high_availability)
    error_message = "mongodb_high_availability must be Disabled or ZoneRedundantPreferred."
  }
}
