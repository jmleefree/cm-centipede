terraform {
  required_version = ">= 1.6"
  required_providers {
    aws   = { source = "hashicorp/aws", version = "~> 5.0" }
    vault = { source = "hashicorp/vault", version = "~> 4.0" }
    tls   = { source = "hashicorp/tls", version = "~> 4.0" }
    local = { source = "hashicorp/local", version = "~> 2.4" }
  }
}

# The vault provider reads the VAULT_ADDR / VAULT_TOKEN environment variables automatically.
provider "vault" {}

# The password of the servers installed on the VM (secret/vm/aws, registered from
# TF_VAR_aws_vm_server_password by register-creds.sh). Read only when there are
# servers to install, so a VM without them needs no such secret.
data "vault_kv_secret_v2" "vm" {
  count = length(var.aws_vm_servers) > 0 ? 1 : 0

  mount = "secret"
  name  = "vm/aws"
}

# The credentials come from OpenBao (secret/csp/aws) as AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY, exported by scripts/lib/csp-env.sh: a data source would keep
# them in the state.
provider "aws" {
  region = var.aws_region
}
