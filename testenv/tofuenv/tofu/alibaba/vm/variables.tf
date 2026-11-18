variable "alibaba_region" {
  description = "Alibaba Cloud region ID"
  type        = string
  default     = "ap-northeast-2"
}

variable "alibaba_name_prefix" {
  description = "Resource name prefix, short for centipede tofu. Must match the network module, since the VPC, vSwitch and security group are looked up by these names"
  type        = string
  default     = "cptf"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,19}$", var.alibaba_name_prefix))
    error_message = "Prefix must be 2-20 characters of lowercase letters, digits and hyphens, starting with a lowercase letter."
  }
}

variable "alibaba_instance_type" {
  description = "ECS instance type. List them with ./scripts/alibaba-db-versions.sh server"
  type        = string
  default     = "ecs.t6-c1m2.large"
}

# Anchored on the plain 20 GB image: a looser ^ubuntu_22_04_x64 also matches the
# 100 GB GPU driver + CUDA image, and the most recent match is the one used.
variable "alibaba_image_name_regex" {
  description = "Regex matched against the names of the system (Alibaba-provided) images; the most recent match is used"
  type        = string
  default     = "^ubuntu_22_04_x64_20G_alibase_"
}

# The system disk is the only disk the VM has, and the filesystem test data lands
# on it, so it has to hold the whole dummy total.
variable "alibaba_vm_volume_size" {
  description = "System disk size in GB (20-500). Fixed at creation: changing it on a prepared VM re-creates the VM"
  type        = number
  default     = 40

  validation {
    condition     = var.alibaba_vm_volume_size >= 20 && var.alibaba_vm_volume_size <= 500 && floor(var.alibaba_vm_volume_size) == var.alibaba_vm_volume_size
    error_message = "alibaba_vm_volume_size must be a whole number of GB from 20 to 500."
  }
}

variable "alibaba_vm_disk_category" {
  description = "System disk category, e.g. cloud_essd, cloud_efficiency, cloud_auto"
  type        = string
  default     = "cloud_essd"
}

variable "alibaba_vm_bandwidth_out" {
  description = "Public IP bandwidth in Mbps (1-100), billed by traffic. Any value above 0 gives the VM a public IP"
  type        = number
  default     = 10

  validation {
    condition     = var.alibaba_vm_bandwidth_out >= 1 && var.alibaba_vm_bandwidth_out <= 100
    error_message = "alibaba_vm_bandwidth_out must be 1-100: 0 would leave the VM without a public IP."
  }
}

variable "ssh_key_dir" {
  description = "Directory where the generated SSH private key (pem) is stored (container path)"
  type        = string
  default     = "/work/ssh_keys"
}

variable "alibaba_data_path" {
  description = "Path for the filesystem migration test data (gendata basePath). Alibaba images log in as root, so it lives under /root"
  type        = string
  default     = "/root/testdata"
}
