terraform {
  required_version = ">= 1.6"
  required_providers {
    alicloud = { source = "aliyun/alicloud", version = "~> 2.2" }
    tls      = { source = "hashicorp/tls", version = "~> 4.0" }
    local    = { source = "hashicorp/local", version = "~> 2.4" }
  }
}

# The credentials come from OpenBao (secret/csp/alibaba) as ALIBABA_CLOUD_ACCESS_KEY_ID /
# _SECRET, exported by scripts/lib/csp-env.sh: a data source would keep them in the state.
provider "alicloud" {
  region = var.alibaba_region
}
