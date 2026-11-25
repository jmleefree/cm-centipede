variable "alibaba_region" {
  description = "Alibaba Cloud region ID"
  type        = string
  default     = "ap-northeast-2"
}

# The settings the matrix creates instances with, read here only to list what
# fits them. Defaults match tofu/alibaba/rdbms.
variable "alibaba_zone" {
  type    = string
  default = "ap-northeast-2a"
}

variable "mysql_category" {
  type    = string
  default = "Basic"
}

variable "mariadb_category" {
  type    = string
  default = "HighAvailability"
}

variable "postgresql_category" {
  type    = string
  default = "Basic"
}
