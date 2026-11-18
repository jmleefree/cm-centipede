variable "alibaba_region" {
  description = "Alibaba Cloud region ID"
  type        = string
  default     = "ap-northeast-2"
}

# The settings .env makes, read here only to list what fits them. Defaults match
# tofu/alibaba/database and tofu/alibaba/vm.
variable "alibaba_zone" {
  type    = string
  default = "ap-northeast-2a"
}

variable "alibaba_mysql_category" {
  type    = string
  default = "Basic"
}

variable "alibaba_mariadb_category" {
  type    = string
  default = "HighAvailability"
}

variable "alibaba_postgres_category" {
  type    = string
  default = "Basic"
}

variable "alibaba_db_storage_type" {
  type    = string
  default = "cloud_essd"
}

variable "alibaba_mysql_version" {
  type    = string
  default = "8.0"
}

variable "alibaba_mariadb_version" {
  type    = string
  default = "10.6"
}

variable "alibaba_postgres_version" {
  type    = string
  default = "14.0"
}

variable "alibaba_vm_disk_category" {
  type    = string
  default = "cloud_essd"
}
