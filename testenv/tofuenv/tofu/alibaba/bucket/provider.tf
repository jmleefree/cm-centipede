terraform {
  required_version = ">= 1.6"
  required_providers {
    alicloud = { source = "aliyun/alicloud", version = "~> 2.2" }
  }
}

# The credentials come from OpenBao (secret/csp/alibaba) as ALIBABA_CLOUD_ACCESS_KEY_ID /
# _SECRET, exported by scripts/lib/csp-env.sh: a data source would keep them in the state.

# OSS needs no VPC; the bucket is created in the provider's region.
provider "alicloud" {
  region = var.alibaba_region
}
