variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_bucket_name" {
  description = "S3 bucket name (must be globally unique)"
  type        = string
}
