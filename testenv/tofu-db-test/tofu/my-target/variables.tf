variable "host" {
  description = "Target instance host. On NCP this is the console-issued public domain"
  type        = string
}

variable "port" {
  type    = number
  default = 3306
}

variable "username" {
  description = "Master user of the managed instance"
  type        = string
}

# Set as TF_VAR_password by lib/tofu.sh (target_db_create), never written to
# matrix.auto.tfvars.json: that file stays on disk after the cell.
variable "password" {
  type      = string
  sensitive = true
}

variable "databases" {
  description = "The cell's target databases: created empty here, dropped when the cell ends. One entry per source database the cell migrates"
  type        = list(string)

  validation {
    condition     = length(var.databases) > 0
    error_message = "databases must name at least one database."
  }
}
