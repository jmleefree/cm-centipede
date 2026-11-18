terraform {
  required_version = ">= 1.6"
  required_providers {
    alicloud = { source = "aliyun/alicloud", version = "~> 2.2" }
    vault    = { source = "hashicorp/vault", version = "~> 4.0" }
  }
}

provider "vault" {}

data "vault_kv_secret_v2" "alibaba" {
  mount = "secret"
  name  = "csp/alibaba"
}

# Read the DB master password from OpenBao (secret/db/alibaba). RDS and MongoDB share it.
data "vault_kv_secret_v2" "db" {
  mount = "secret"
  name  = "db/alibaba"
}

provider "alicloud" {
  access_key = data.vault_kv_secret_v2.alibaba.data["ALIBABA_ACCESS_KEY_ID"]
  secret_key = data.vault_kv_secret_v2.alibaba.data["ALIBABA_ACCESS_KEY_SECRET"]
  region     = var.alibaba_region
}
