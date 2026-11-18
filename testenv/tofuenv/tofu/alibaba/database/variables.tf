variable "alibaba_region" {
  description = "Alibaba Cloud region ID"
  type        = string
  default     = "ap-northeast-2"
}

variable "alibaba_zone" {
  description = "Zone of the network module's vSwitch; every instance is created in it"
  type        = string
  default     = "ap-northeast-2a"
}

variable "alibaba_name_prefix" {
  description = "Resource name prefix, short for centipede tofu; must match the network module, since the VPC and vSwitch are looked up by these names"
  type        = string
  default     = "cptf"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,19}$", var.alibaba_name_prefix))
    error_message = "Prefix must be 2-20 characters of lowercase letters, digits and hyphens, starting with a lowercase letter."
  }
}

variable "allowed_cidr" {
  description = "CIDR put on the RDS and MongoDB IP whitelists; wide open by default"
  type        = string
  default     = "0.0.0.0/0"
}

variable "alibaba_db_name" {
  description = "Initial database name, created on mysql, mariadb and postgresql"
  type        = string
  default     = "testdb"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_-]{0,63}$", var.alibaba_db_name))
    error_message = "alibaba_db_name must start with a lowercase letter and hold lowercase letters, digits, underscores and hyphens, 64 characters at most."
  }
}

variable "alibaba_db_username" {
  description = "RDS master (privileged) account. MongoDB does not use it: its replica set account is always root"
  type        = string
  default     = "dbadmin"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{1,15}$", var.alibaba_db_username))
    error_message = "alibaba_db_username must be 2-16 characters of lowercase letters, digits and underscores, starting with a letter."
  }
}

# Which engines this module runs. Not set in .env: prepare.sh and teardown.sh
# work it out from --engine and from what the state already holds, and export it
# for each apply. The default - every engine - is what a plain apply gets.
variable "alibaba_db_engines" {
  description = "Engines to run: any of mysql, mariadb, postgres, mongodb"
  type        = list(string)
  default     = ["mysql", "mariadb", "postgres", "mongodb"]

  validation {
    condition     = alltrue([for e in var.alibaba_db_engines : contains(["mysql", "mariadb", "postgres", "mongodb"], e)])
    error_message = "alibaba_db_engines may only contain mysql, mariadb, postgres and mongodb."
  }
}

# ---------------------------------------------------------------------------
# RDS (mysql, mariadb, postgres)
#   The instance class must exist for the engine, version, edition, storage type
#   and zone together; the module checks that at plan time. List the classes with
#   ./scripts/alibaba-db-versions.sh <mysql|mariadb|postgresql>
# ---------------------------------------------------------------------------
# The edition is set per engine: what is sold differs by engine, and the class
# has to match it. Basic is a single node; HighAvailability adds a standby, in
# the same zone here since the module has one vSwitch.
variable "alibaba_mysql_category" {
  description = "RDS MySQL edition: Basic or HighAvailability"
  type        = string
  default     = "Basic"

  validation {
    condition     = contains(["Basic", "HighAvailability"], var.alibaba_mysql_category)
    error_message = "alibaba_mysql_category must be Basic or HighAvailability."
  }
}

# MariaDB is sold as HighAvailability only (ap-northeast-2a, checked with
# ./scripts/alibaba-db-versions.sh mariadb).
variable "alibaba_mariadb_category" {
  description = "RDS MariaDB edition: Basic or HighAvailability"
  type        = string
  default     = "HighAvailability"

  validation {
    condition     = contains(["Basic", "HighAvailability"], var.alibaba_mariadb_category)
    error_message = "alibaba_mariadb_category must be Basic or HighAvailability."
  }
}

variable "alibaba_postgres_category" {
  description = "RDS PostgreSQL edition: Basic or HighAvailability"
  type        = string
  default     = "Basic"

  validation {
    condition     = contains(["Basic", "HighAvailability"], var.alibaba_postgres_category)
    error_message = "alibaba_postgres_category must be Basic or HighAvailability."
  }
}

variable "alibaba_mysql_instance_class" {
  description = "RDS MySQL instance class"
  type        = string
  default     = "mysql.n2.medium.1"
}

variable "alibaba_mariadb_instance_class" {
  description = "RDS MariaDB instance class (a HighAvailability class, *.2c)"
  type        = string
  default     = "mariadb.n2.medium.2c"
}

variable "alibaba_postgres_instance_class" {
  description = "RDS PostgreSQL instance class"
  type        = string
  default     = "pg.n2.medium.1"
}

variable "alibaba_db_allocated_storage" {
  description = "RDS storage in GB, each RDS engine, in 5 GB steps"
  type        = number
  default     = 20
}

variable "alibaba_db_storage_type" {
  description = "RDS storage type: cloud_essd, cloud_essd2, cloud_essd3, cloud_ssd, local_ssd, general_essd"
  type        = string
  default     = "cloud_essd"
}

variable "alibaba_mysql_version" {
  description = "RDS MySQL engine version, e.g. 8.0"
  type        = string
  default     = "8.0"
}

variable "alibaba_mariadb_version" {
  description = "RDS MariaDB engine version"
  type        = string
  default     = "10.6"
}

variable "alibaba_postgres_version" {
  description = "RDS PostgreSQL engine version, e.g. 14.0"
  type        = string
  default     = "14.0"
}

# ---------------------------------------------------------------------------
# ApsaraDB for MongoDB (replica set)
# ---------------------------------------------------------------------------
variable "alibaba_mongodb_version" {
  description = "MongoDB engine version, e.g. 7.0"
  type        = string
  default     = "7.0"
}

variable "alibaba_mongodb_instance_class" {
  description = "MongoDB replica set instance class. It must suit alibaba_mongodb_storage_type"
  type        = string
  default     = "mdb.shard.4x.large.d"
}

variable "alibaba_mongodb_storage" {
  description = "MongoDB storage in GB, in 10 GB steps"
  type        = number
  default     = 20
}

variable "alibaba_mongodb_storage_type" {
  description = "MongoDB storage type: cloud_essd1, cloud_essd2, cloud_essd3, cloud_auto, local_ssd"
  type        = string
  default     = "cloud_essd1"
}

variable "alibaba_mongodb_replication_factor" {
  description = "Replica set nodes: 1, 3, 5 or 7"
  type        = number
  default     = 3

  validation {
    condition     = contains([1, 3, 5, 7], var.alibaba_mongodb_replication_factor)
    error_message = "alibaba_mongodb_replication_factor must be 1, 3, 5 or 7."
  }
}
