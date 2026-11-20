output "bucket_name" {
  description = "Name of the created container (gendata uses it as the upload target)"
  value       = azurerm_storage_container.this.name
}

output "bucket_region" {
  description = "Region of the storage account; Blob access does not use it"
  value       = try(local.storage_account.location, null)
}

output "storage_account_name" {
  description = "The existing storage account the container is in (AZURE_S3_ACCESS_KEY)"
  value       = local.storage_account_name
}

output "storage_account_resource_group" {
  value = try(local.storage_account.resource_group_name, null)
}

output "s3_endpoint" {
  description = "Blob service endpoint (Azure Blob has no S3 API; gendata speaks to it with the azblob SDK)"
  value       = "${local.storage_account_name}.blob.core.windows.net"
}

output "name_prefix" {
  description = "Name prefix, and the tofu workspace this environment lives in"
  value       = var.azure_name_prefix
}
