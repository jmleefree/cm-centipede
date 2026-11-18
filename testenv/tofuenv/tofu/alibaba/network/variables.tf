variable "alibaba_region" {
  description = "Alibaba Cloud region ID"
  type        = string
  default     = "ap-northeast-2"
}

variable "alibaba_zone" {
  description = "Zone the vSwitch is placed in. ECS, RDS and MongoDB all use this one vSwitch, so the zone must offer all three"
  type        = string
  default     = "ap-northeast-2a"
}

variable "alibaba_name_prefix" {
  description = "Resource name prefix, short for centipede tofu. The vm and database modules look the VPC, vSwitch and security group up by these names"
  type        = string
  default     = "cptf"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,19}$", var.alibaba_name_prefix))
    error_message = "Prefix must be 2-20 characters of lowercase letters, digits and hyphens, starting with a lowercase letter."
  }
}

variable "alibaba_vpc_cidr" {
  description = "VPC IPv4 CIDR, inside 10.0.0.0/8, 172.16.0.0/12 or 192.168.0.0/16. The vSwitch takes the first /24 above .0 of it"
  type        = string
  default     = "10.20.0.0/16"
}

variable "allowed_cidr" {
  description = "CIDR allowed for security group inbound rules; wide open by default"
  type        = string
  default     = "0.0.0.0/0"
}
