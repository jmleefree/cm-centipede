variable "gcp_region" {
  description = "GCP region, e.g. asia-northeast3 (Seoul). The subnet and the static IP are created there"
  type        = string
  default     = "asia-northeast3"
}

variable "gcp_zone" {
  description = "Zone the VM is created in; must be in gcp_region, e.g. asia-northeast3-a"
  type        = string
  default     = "asia-northeast3-a"
}

variable "gcp_name_prefix" {
  description = "Resource name prefix, short for centipede tofu. Starts the name of the VM and of its VPC, subnet, firewall rule and address"
  type        = string
  default     = "cptf"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,11}$", var.gcp_name_prefix))
    error_message = "Prefix must be 2-12 characters of lowercase letters, digits and hyphens, starting with a lowercase letter."
  }
}

variable "allowed_cidr" {
  description = "CIDR allowed through the SSH firewall rule; wide open by default"
  type        = string
  default     = "0.0.0.0/0"
}

variable "gcp_machine_type" {
  description = "Machine type, e.g. e2-medium. List them with ./scripts/gcp-db-versions.sh server"
  type        = string
  default     = "e2-medium"
}

# The boot disk is the only disk the VM has, and the filesystem test data lands
# on it, so it has to hold the whole dummy total.
variable "gcp_vm_volume_size" {
  description = "Boot disk size in GB (10 or more). Fixed at creation: changing it on a prepared VM re-creates the VM"
  type        = number
  default     = 30

  validation {
    condition     = var.gcp_vm_volume_size >= 10 && floor(var.gcp_vm_volume_size) == var.gcp_vm_volume_size
    error_message = "gcp_vm_volume_size must be a whole number of GB, 10 or more."
  }
}

# Persistent Disk types. Machine series that only take Hyperdisk (c4, n4, ...)
# do not work with these.
variable "gcp_vm_disk_type" {
  description = "Boot disk type: pd-standard, pd-balanced or pd-ssd"
  type        = string
  default     = "pd-balanced"

  validation {
    condition     = contains(["pd-standard", "pd-balanced", "pd-ssd"], var.gcp_vm_disk_type)
    error_message = "gcp_vm_disk_type must be pd-standard, pd-balanced or pd-ssd."
  }
}

variable "gcp_subnet_cidr" {
  description = "Address range of the subnet the VM is in (a GCP VPC has none of its own)"
  type        = string
  default     = "10.40.0.0/24"

  validation {
    condition     = can(cidrhost(var.gcp_subnet_cidr, 0))
    error_message = "gcp_subnet_cidr must be a CIDR, e.g. 10.40.0.0/24."
  }
}

variable "gcp_image_project" {
  description = "Project of the public image"
  type        = string
  default     = "ubuntu-os-cloud"
}

variable "gcp_image_family" {
  description = "Image family; the latest image of it is used"
  type        = string
  default     = "ubuntu-2204-lts"
}

variable "ssh_key_dir" {
  description = "Directory where the generated SSH private key (pem) is stored (container path)"
  type        = string
  default     = "/work/ssh_keys"
}

variable "gcp_data_path" {
  description = "Path for the filesystem migration test data (gendata basePath). It must be writable by ubuntu, the login account"
  type        = string
  default     = "/home/ubuntu/testdata"
}

variable "gcp_project_id" {
  description = "Project the provider works in (GCP_PROJECT_ID). Not set in .env: scripts/lib/csp-env.sh exports it as TF_VAR_gcp_project_id from OpenBao (secret/csp/gcp)"
  type        = string

  validation {
    condition     = var.gcp_project_id != ""
    error_message = "gcp_project_id is empty: GCP_PROJECT_ID is not registered in OpenBao (secret/csp/gcp). Set it in .env and run ./scripts/up.sh."
  }
}
