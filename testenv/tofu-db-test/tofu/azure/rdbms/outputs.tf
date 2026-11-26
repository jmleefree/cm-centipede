# Output names are shared with the other CSPs' rdbms modules, so lib/tofu.sh
# reads one shape for every CSP.
output "host" {
  description = "Server FQDN (MySQL, PostgreSQL), or the SRV name of the mongodb+srv:// string (MongoDB vCore) - lib/tofu.sh resolves that one"
  value       = local.host
}

output "port" {
  description = "Null on MongoDB vCore: the port comes with the SRV record"
  value       = local.port
}

output "host_is_srv" {
  description = "Whether host is an SRV name that has to be resolved to a host and port"
  value       = local.is_mongo
}

output "username" {
  value = var.db_username
}

output "database" {
  description = "Admin database. MongoDB has none, so it is reported as empty there"
  value       = local.is_mongo ? "" : var.db_name
}

output "engine" {
  value = var.engine
}

output "engine_version" {
  value = var.engine_version
}

output "status" {
  description = "Azure reports no server status through azurerm"
  value       = ""
}

output "public_access" {
  value = local.host != null
}

output "csp_name" {
  value = local.name
}

output "csp_id" {
  value = local.id
}

output "resource_group" {
  description = "The column's resource group; a destroy deletes it with everything in it"
  value       = azurerm_resource_group.this.name
}

output "secure_transport" {
  description = "Reported for symmetry with the AWS module, which can turn the CSP default off; on Azure the default is left as it is"
  value       = "csp-default"
}
