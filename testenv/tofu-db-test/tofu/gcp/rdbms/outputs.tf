# Output names are shared with the other CSPs' rdbms modules, so lib/tofu.sh
# reads one shape for every CSP.
output "host" {
  description = "Instance public IP"
  value       = google_sql_database_instance.this.public_ip_address
}

output "port" {
  value = local.port
}

output "username" {
  value = var.db_username
}

output "database" {
  value = var.db_name
}

output "engine" {
  value = var.engine
}

output "engine_version" {
  value = var.engine_version
}

output "status" {
  description = "Cloud SQL reports no instance state through the provider"
  value       = ""
}

output "public_access" {
  value = google_sql_database_instance.this.public_ip_address != null
}

output "csp_name" {
  value = local.name
}

output "csp_id" {
  description = "<project>:<region>:<instance>, what the Cloud SQL console and Auth Proxy take"
  value       = google_sql_database_instance.this.connection_name
}

output "secure_transport" {
  description = "Reported for symmetry with the AWS module; ssl_mode lets plaintext and TLS in, and the matrix connects with TLS when it prefers"
  value       = "csp-default"
}
