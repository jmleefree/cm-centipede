terraform {
  required_version = ">= 1.6"
  required_providers {
    ncloud = { source = "NaverCloudPlatform/ncloud", version = "~> 4.0" }
  }
}

# The CSP keys are not read here. lib/csp-env.sh exports them as
# NCLOUD_ACCESS_KEY / NCLOUD_SECRET_KEY before each plan/apply/destroy, which
# the provider reads itself. A vault_kv_secret_v2 data source would keep them in
# the state.
provider "ncloud" {
  region      = var.ncp_region
  site        = "public"
  support_vpc = true # Required: the provider only supports the VPC environment.
}
