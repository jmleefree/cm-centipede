output "bucket_name" {
  description = "Name of the created bucket (gendata uses it as the upload target)"
  value       = alicloud_oss_bucket.this.bucket
}

output "bucket_region" {
  description = "Region ID (gendata turns it into the OSS endpoint)"
  value       = var.alibaba_region
}

output "s3_endpoint" {
  description = "S3-compatible API endpoint"
  value       = local.oss_endpoint
}

output "s3cmd_hint" {
  description = "Example command for checking the bucket with the AWS CLI"
  value       = "aws --endpoint-url https://${local.oss_endpoint} s3 ls s3://${alicloud_oss_bucket.this.bucket}"
}

output "name_prefix" {
  description = "Name prefix, and the tofu workspace this environment lives in"
  value       = var.alibaba_name_prefix
}
