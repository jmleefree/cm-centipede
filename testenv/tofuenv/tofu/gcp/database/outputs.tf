# ---------------------------------------------------------------------------
# Common
#   Output names match the other CSPs' modules so gendata can read them
#   CSP-agnostically. *_host is the instance's public IP. An engine left out of
#   var.gcp_db_engines has no resource, and all of its outputs are null.
# ---------------------------------------------------------------------------
output "db_name" {
  value = var.gcp_db_name
}

output "db_username" {
  description = "Admin account on both engines"
  value       = var.gcp_db_username
}

output "db_password" {
  description = "DB admin password, shared by both engines (read with: tofu output -raw db_password)"
  value       = local.db_password
  sensitive   = true
}

# --- Cloud SQL for MySQL ---
output "mysql_host" {
  description = "MySQL instance public IP"
  value       = one(google_sql_database_instance.mysql[*].public_ip_address)
}
output "mysql_port" {
  value = local.want_mysql ? local.mysql_port : null
}
output "mysql_instance_name" {
  value = one(google_sql_database_instance.mysql[*].name)
}
output "mysql_connection_name" {
  description = "<project>:<region>:<instance>, what the Cloud SQL Auth Proxy takes"
  value       = one(google_sql_database_instance.mysql[*].connection_name)
}
output "mysql_connection_uri" {
  value = local.want_mysql ? format("mysql://%s:%s@%s:%d/%s",
    var.gcp_db_username, local.db_password, google_sql_database_instance.mysql[0].public_ip_address,
    local.mysql_port, var.gcp_db_name
  ) : null
  sensitive = true
}

# --- Cloud SQL for PostgreSQL ---
output "postgres_host" {
  description = "PostgreSQL instance public IP"
  value       = one(google_sql_database_instance.postgres[*].public_ip_address)
}
output "postgres_port" {
  value = local.want_postgres ? local.postgres_port : null
}
output "postgres_instance_name" {
  value = one(google_sql_database_instance.postgres[*].name)
}
output "postgres_connection_name" {
  description = "<project>:<region>:<instance>, what the Cloud SQL Auth Proxy takes"
  value       = one(google_sql_database_instance.postgres[*].connection_name)
}
output "postgres_connection_uri" {
  value = local.want_postgres ? format("postgresql://%s:%s@%s:%d/%s",
    var.gcp_db_username, local.db_password, google_sql_database_instance.postgres[0].public_ip_address,
    local.postgres_port, var.gcp_db_name
  ) : null
  sensitive = true
}

output "name_prefix" {
  description = "Name prefix, and the tofu workspace this environment lives in"
  value       = var.gcp_name_prefix
}
