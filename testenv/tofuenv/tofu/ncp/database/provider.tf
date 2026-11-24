terraform {
  required_version = ">= 1.6"
  required_providers {
    ncloud = { source = "NaverCloudPlatform/ncloud", version = "~> 4.0" }
    vault  = { source = "hashicorp/vault", version = "~> 4.0" }
  }
}

# The vault provider reads the VAULT_ADDR / VAULT_TOKEN environment variables automatically.
provider "vault" {}

# DB master password (secret/db/ncp)
data "vault_kv_secret_v2" "db" {
  mount = "secret"
  name  = "db/ncp"
}

# The credentials come from OpenBao (secret/csp/ncp) as NCLOUD_ACCESS_KEY /
# NCLOUD_SECRET_KEY, exported by scripts/lib/csp-env.sh: a data source would keep them
# in the state.
provider "ncloud" {
  region      = var.ncp_region
  site        = "public"
  support_vpc = true
}
