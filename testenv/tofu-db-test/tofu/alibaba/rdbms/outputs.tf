# Output names are shared with tofu/aws/rdbms and tofu/ncp/rdbms, so lib/tofu.sh
# reads one shape for every CSP. host is the public endpoint.
output "host" {
  description = "Public connection string (RDS) or the Primary's public address (MongoDB)"
  value       = local.host
}

output "port" {
  value = local.port
}

output "username" {
  description = "The RDS master account, or root on MongoDB (a replica set has that one account)"
  value       = local.username
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
  description = "RDS instance status. The MongoDB resource reports none"
  value       = local.is_mongo ? "" : try(alicloud_db_instance.this[0].status, "")
}

output "public_access" {
  value = local.host != null
}

output "csp_name" {
  value = local.instance_name
}

output "csp_id" {
  value = local.id
}

output "secure_transport" {
  description = "Reported for symmetry with the AWS module, which can turn the CSP default off; on Alibaba the default is left as it is"
  value       = "csp-default"
}

# The instance ID again, under the name lib/tofu.sh hands to the cell module:
# tofu/alibaba-target creates a cell's databases through the CSP API
# (alicloud_db_database), addressed by it.
output "instance_no" {
  description = "RDS instance ID, for tofu/alibaba-target"
  value       = local.id
}
