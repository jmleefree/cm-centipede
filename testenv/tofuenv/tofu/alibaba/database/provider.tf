terraform {
  required_version = ">= 1.6"
  required_providers {
    alicloud = { source = "aliyun/alicloud", version = "~> 2.2" }
    vault    = { source = "hashicorp/vault", version = "~> 4.0" }
  }
}

# The vault provider reads the VAULT_ADDR / VAULT_TOKEN environment variables automatically.
provider "vault" {}

# Read the DB master password from OpenBao (secret/db/alibaba). RDS and MongoDB share it.
data "vault_kv_secret_v2" "db" {
  mount = "secret"
  name  = "db/alibaba"
}

# The credentials come from OpenBao (secret/csp/alibaba) as ALIBABA_CLOUD_ACCESS_KEY_ID /
# _SECRET, exported by scripts/lib/csp-env.sh: a data source would keep them in the state.
provider "alicloud" {
  region = var.alibaba_region
}
