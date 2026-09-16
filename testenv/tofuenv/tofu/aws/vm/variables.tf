variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "aws_vm_volume_size" {
  description = "VM root volume size in GB"
  type        = number
  default     = 20
}

variable "allowed_cidr" {
  description = "CIDR allowed for inbound SSH (22); wide open by default"
  type        = string
  default     = "0.0.0.0/0"
}

variable "aws_name_prefix" {
  description = "Resource name prefix, short for centipede tofu"
  type        = string
  default     = "cptf"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,19}$", var.aws_name_prefix))
    error_message = "Prefix must be 2-20 characters of lowercase letters, digits and hyphens, starting with a lowercase letter."
  }
}

variable "ssh_key_dir" {
  description = "Directory where the generated SSH private key (pem) is stored (container path)"
  type        = string
  default     = "/work/ssh_keys"
}

variable "aws_data_path" {
  description = "Path for the filesystem migration test data (gendata basePath). AWS images log in as ubuntu, so it lives under /home/ubuntu"
  type        = string
  default     = "/home/ubuntu/testdata"
}
