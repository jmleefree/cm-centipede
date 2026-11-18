terraform {
  required_version = ">= 1.6"
  required_providers {
    alicloud = { source = "aliyun/alicloud", version = "~> 2.2" }
    vault    = { source = "hashicorp/vault", version = "~> 4.0" }
  }
}

# The vault provider reads the VAULT_ADDR / VAULT_TOKEN environment variables automatically.
provider "vault" {}

# Read the Alibaba credentials from OpenBao (secret/csp/alibaba).
data "vault_kv_secret_v2" "alibaba" {
  mount = "secret"
  name  = "csp/alibaba"
}

provider "alicloud" {
  access_key = data.vault_kv_secret_v2.alibaba.data["ALIBABA_ACCESS_KEY_ID"]
  secret_key = data.vault_kv_secret_v2.alibaba.data["ALIBABA_ACCESS_KEY_SECRET"]
  region     = var.alibaba_region
}
