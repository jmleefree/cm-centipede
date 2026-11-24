terraform {
  required_version = ">= 1.6"
  required_providers {
    ncloud = { source = "NaverCloudPlatform/ncloud", version = "~> 4.0" }
    tls    = { source = "hashicorp/tls", version = "~> 4.0" }
    local  = { source = "hashicorp/local", version = "~> 2.4" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

# The credentials come from OpenBao (secret/csp/ncp) as NCLOUD_ACCESS_KEY /
# NCLOUD_SECRET_KEY, exported by scripts/lib/csp-env.sh: a data source would keep them
# in the state.
provider "ncloud" {
  region      = var.ncp_region
  site        = "public"
  support_vpc = true
}
