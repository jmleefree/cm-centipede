terraform {
  required_version = ">= 1.6"
  required_providers {
    alicloud = { source = "aliyun/alicloud", version = "~> 2.2" }
    vault    = { source = "hashicorp/vault", version = "~> 4.0" }
  }
}

# The vault provider reads VAULT_ADDR / VAULT_TOKEN from the environment.
provider "vault" {}

# The managed-DB master password (secret/db/alibaba). RDS and MongoDB share it.
# Nothing sensitive is passed in as a variable: the matrix never has to hold it
# to run an apply.
data "vault_kv_secret_v2" "db" {
  mount = "secret"
  name  = "db/alibaba"
}

# The CSP keys are not read here. lib/csp-env.sh exports them as
# ALIBABA_CLOUD_ACCESS_KEY_ID / ALIBABA_CLOUD_ACCESS_KEY_SECRET before each
# plan/apply/destroy, which the provider reads itself. A vault_kv_secret_v2 data
# source would keep them in the state.
provider "alicloud" {
  region = var.alibaba_region
}
