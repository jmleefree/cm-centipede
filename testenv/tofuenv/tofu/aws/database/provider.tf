terraform {
  required_version = ">= 1.6"
  required_providers {
    aws   = { source = "hashicorp/aws", version = "~> 5.0" }
    vault = { source = "hashicorp/vault", version = "~> 4.0" }
  }
}

# The vault provider reads the VAULT_ADDR / VAULT_TOKEN environment variables automatically.
provider "vault" {}

# DB master password (secret/db/aws)
data "vault_kv_secret_v2" "db" {
  mount = "secret"
  name  = "db/aws"
}

# The credentials come from OpenBao (secret/csp/aws) as AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY, exported by scripts/lib/csp-env.sh: a data source would keep
# them in the state.
provider "aws" {
  region = var.aws_region
}
