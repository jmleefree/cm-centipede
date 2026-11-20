variable "azure_region" {
  description = "Azure region (what Azure calls the location), e.g. koreacentral"
  type        = string
  default     = "koreacentral"
}

variable "azure_name_prefix" {
  description = "Resource name prefix, short for centipede tofu. Names the resource group (<prefix>-vm-rg) and everything in it"
  type        = string
  default     = "cptf"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,11}$", var.azure_name_prefix))
    error_message = "Prefix must be 2-12 characters of lowercase letters, digits and hyphens, starting with a lowercase letter."
  }
}

variable "allowed_cidr" {
  description = "CIDR allowed for NSG inbound rules; wide open by default"
  type        = string
  default     = "0.0.0.0/0"
}

variable "azure_vm_size" {
  description = "VM size. List them with ./scripts/azure-db-versions.sh server"
  type        = string
  default     = "Standard_B2s"
}

# The OS disk is the only disk the VM has, and the filesystem test data lands on
# it, so it has to hold the whole dummy total.
variable "azure_vm_volume_size" {
  description = "OS disk size in GB (30 or more). Fixed at creation: changing it on a prepared VM re-creates the VM"
  type        = number
  default     = 30

  validation {
    condition     = var.azure_vm_volume_size >= 30 && floor(var.azure_vm_volume_size) == var.azure_vm_volume_size
    error_message = "azure_vm_volume_size must be a whole number of GB, 30 or more."
  }
}

variable "azure_vm_disk_type" {
  description = "OS disk storage type: Standard_LRS, StandardSSD_LRS or Premium_LRS"
  type        = string
  default     = "StandardSSD_LRS"

  validation {
    condition     = contains(["Standard_LRS", "StandardSSD_LRS", "Premium_LRS"], var.azure_vm_disk_type)
    error_message = "azure_vm_disk_type must be Standard_LRS, StandardSSD_LRS or Premium_LRS."
  }
}

variable "azure_vnet_cidr" {
  description = "VNet address space. The subnet takes the first /24 above .0 of it"
  type        = string
  default     = "10.30.0.0/16"
}

variable "azure_image_offer" {
  description = "Canonical marketplace image offer"
  type        = string
  default     = "0001-com-ubuntu-server-jammy"
}

variable "azure_image_sku" {
  description = "Canonical marketplace image SKU"
  type        = string
  default     = "22_04-lts-gen2"
}

variable "ssh_key_dir" {
  description = "Directory where the generated SSH private key (pem) is stored (container path)"
  type        = string
  default     = "/work/ssh_keys"
}

variable "azure_data_path" {
  description = "Path for the filesystem migration test data (gendata basePath). It must be writable by azureuser, the login account"
  type        = string
  default     = "/home/azureuser/testdata"
}
