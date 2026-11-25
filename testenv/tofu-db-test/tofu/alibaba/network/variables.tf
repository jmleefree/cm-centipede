variable "alibaba_region" {
  description = "Alibaba Cloud region ID"
  type        = string
  default     = "ap-northeast-2"
}

variable "alibaba_zone" {
  description = "Zone the vSwitch is placed in. Every instance uses this one vSwitch, so the zone must sell every engine the matrix runs"
  type        = string
  default     = "ap-northeast-2a"
}

variable "name_prefix" {
  description = "Resource name prefix, short for centipede tofu matrix. tofu/alibaba/rdbms looks the VPC and vSwitch up by these names"
  type        = string
  default     = "cptfm"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,5}$", var.name_prefix))
    error_message = "Prefix must be 2-6 characters of lowercase letters and digits, starting with a letter (MATRIX_NAME_PREFIX)."
  }
}

variable "alibaba_vpc_cidr" {
  description = "VPC IPv4 CIDR, inside 10.0.0.0/8, 172.16.0.0/12 or 192.168.0.0/16. The vSwitch takes the first /24 above .0 of it"
  type        = string
  default     = "10.30.0.0/16"
}
