variable "alibaba_region" {
  description = "Alibaba Cloud region ID"
  type        = string
  default     = "ap-northeast-2"
}

variable "alibaba_zone" {
  description = "Zone of the network module's vSwitch; the instance is created in it"
  type        = string
  default     = "ap-northeast-2a"
}

variable "name_prefix" {
  description = "Resource name prefix; must match tofu/alibaba/network, since the VPC and vSwitch are looked up by these names"
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
  description = "Managed engine: mysql, mariadb, postgresql or mongodb"
  type        = string

  validation {
    condition     = contains(["mysql", "mariadb", "postgresql", "mongodb"], var.engine)
    error_message = "engine must be one of mysql, mariadb, postgresql, mongodb."
  }
}

# Alibaba sells a version line, not a patch release: 8.0, 10.6, 14.0, 7.0.
variable "engine_version" {
  description = "Engine version line, e.g. 8.0 / 10.6 / 14.0 / 7.0"
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.engine_version))
    error_message = "Expected a version line like 8.0 or 14.0. Run ./scripts/alibaba-db-versions.sh to list what the zone offers."
  }
}

variable "db_name" {
  description = "Admin database created with an RDS instance; the matrix connects to it to create and drop each cell's target database. Not used for MongoDB"
  type        = string
  default     = "matrixadm"
}

variable "db_username" {
  description = "RDS master (privileged) account. MongoDB does not use it: its replica set account is always root"
  type        = string
  default     = "dbadmin"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{1,15}$", var.db_username))
    error_message = "db_username must be 2-16 characters of lowercase letters, digits and underscores, starting with a letter."
  }
}

variable "allowed_cidr" {
  description = "CIDR put on the instance's IP whitelist; the matrix host has to be inside it"
  type        = string
  default     = "0.0.0.0/0"
}

# --- RDS (mysql, mariadb, postgresql) ----------------------------------------
# Empty means the per-engine default in main.tf.
variable "instance_class" {
  description = "Instance class (RDS or MongoDB). Empty: mysql.n2.medium.1 / mariadb.n2.medium.2c / pg.n2.medium.1 / mdb.shard.4x.large.d"
  type        = string
  default     = ""
}

variable "category" {
  description = "RDS edition: Basic or HighAvailability. Empty: HighAvailability for MariaDB (the only one sold), Basic otherwise"
  type        = string
  default     = ""

  validation {
    condition     = contains(["", "Basic", "HighAvailability"], var.category)
    error_message = "category must be Basic or HighAvailability."
  }
}

variable "storage_gb" {
  description = "RDS storage in GB, in 5 GB steps"
  type        = number
  default     = 20
}

variable "storage_type" {
  description = "RDS storage type: cloud_essd, cloud_essd2, cloud_essd3, cloud_ssd, local_ssd, general_essd"
  type        = string
  default     = "cloud_essd"
}

# --- ApsaraDB for MongoDB (replica set) --------------------------------------
variable "mongodb_storage_gb" {
  description = "MongoDB storage in GB, in 10 GB steps"
  type        = number
  default     = 20
}

variable "mongodb_storage_type" {
  description = "MongoDB storage type: cloud_essd1, cloud_essd2, cloud_essd3, cloud_auto, local_ssd"
  type        = string
  default     = "cloud_essd1"
}

variable "mongodb_nodes" {
  description = "Replica set nodes: 1, 3, 5 or 7. Which counts are sold depends on the version and class"
  type        = number
  default     = 3

  validation {
    condition     = contains([1, 3, 5, 7], var.mongodb_nodes)
    error_message = "mongodb_nodes must be 1, 3, 5 or 7."
  }
}
