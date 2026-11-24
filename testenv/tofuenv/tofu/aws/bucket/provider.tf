terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

# The credentials come from OpenBao (secret/csp/aws) as AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY, exported by scripts/lib/csp-env.sh: a data source would keep
# them in the state.
provider "aws" {
  region = var.aws_region
}
