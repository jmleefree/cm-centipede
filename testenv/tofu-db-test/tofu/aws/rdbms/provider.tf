terraform {
  required_version = ">= 1.6"
  required_providers {
    aws   = { source = "hashicorp/aws", version = "~> 5.0" }
    vault = { source = "hashicorp/vault", version = "~> 4.0" }
  }
}

provider "vault" {}

# The managed-DB master password (secret/db/aws). Nothing sensitive is passed in
# as a variable: the matrix never has to hold it to run an apply.
data "vault_kv_secret_v2" "db" {
  mount = "secret"
  name  = "db/aws"
}

# The CSP keys are not read here. lib/csp-env.sh exports them as
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY before each plan/apply/destroy, which
# the provider reads itself. A vault_kv_secret_v2 data source would keep them in
# the state.
provider "aws" {
  region = var.aws_region
}
