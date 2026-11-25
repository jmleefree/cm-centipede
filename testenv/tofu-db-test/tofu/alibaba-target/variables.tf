variable "alibaba_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "engine" {
  description = "mysql, mariadb or postgresql. MongoDB never reaches this module - it has no CREATE DATABASE"
  type        = string

  validation {
    condition     = contains(["mysql", "mariadb", "postgresql"], var.engine)
    error_message = "engine must be mysql, mariadb or postgresql."
  }
}

variable "instance_no" {
  description = "The RDS instance ID, from the column's instance_no output"
  type        = string

  validation {
    condition     = length(var.instance_no) > 0
    error_message = "instance_no is empty: the column's instance has no ID yet."
  }
}

variable "databases" {
  description = "The cell's target databases: created empty here, dropped when the cell ends"
  type        = list(string)

  validation {
    condition     = length(var.databases) > 0
    error_message = "databases must name at least one database."
  }
}

variable "owner" {
  description = "Owner (DBOwner) of each PostgreSQL database; ignored for MySQL and MariaDB"
  type        = string
  default     = ""
}
