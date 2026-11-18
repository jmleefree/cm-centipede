# ---------------------------------------------------------------------------
# Alibaba OSS bucket, used as the object storage migration test target.
#   No VPC is required. The S3-compatible API is served on the public endpoint
#   oss-<region>.aliyuncs.com, virtual-hosted style.
#   gendata fills the bucket with objects; this module owns the bucket lifecycle.
#
#   force_destroy deletes whatever gendata put in the bucket on teardown. Unlike
#   NCP, no gendata cleanup run is needed before the destroy.
# ---------------------------------------------------------------------------
locals {
  oss_endpoint = "oss-${var.alibaba_region}.aliyuncs.com"
}

resource "alicloud_oss_bucket" "this" {
  bucket        = var.alibaba_bucket_name
  force_destroy = true
}
