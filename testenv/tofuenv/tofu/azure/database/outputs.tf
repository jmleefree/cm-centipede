# ---------------------------------------------------------------------------
# Common
#   Output names match the other CSPs' modules so gendata can read them
#   CSP-agnostically. *_host is the public endpoint. An engine left out of
#   var.azure_db_engines has no resource, and all of its outputs are null.
# ---------------------------------------------------------------------------
output "db_name" {
  value = var.azure_db_name
}

output "db_username" {
  description = "Admin account on all three engines"
  value       = var.azure_db_username
}

output "db_password" {
  description = "DB admin password, shared by all three engines (read with: tofu output -raw db_password)"
  value       = local.db_password
  sensitive   = true
}

output "resource_group" {
  description = "Resource group holding every database; teardown deletes it"
  value       = azurerm_resource_group.this.name
}

# --- MySQL Flexible Server ---
output "mysql_host" {
  description = "MySQL server FQDN"
  value       = one(azurerm_mysql_flexible_server.mysql[*].fqdn)
}
output "mysql_port" {
  value = local.want_mysql ? local.mysql_port : null
}
output "mysql_server_name" {
  value = one(azurerm_mysql_flexible_server.mysql[*].name)
}
output "mysql_connection_uri" {
  value = local.want_mysql ? format("mysql://%s:%s@%s:%d/%s",
    var.azure_db_username, local.db_password, azurerm_mysql_flexible_server.mysql[0].fqdn,
    local.mysql_port, var.azure_db_name
  ) : null
  sensitive = true
}

# --- PostgreSQL Flexible Server ---
output "postgres_host" {
  description = "PostgreSQL server FQDN"
  value       = one(azurerm_postgresql_flexible_server.postgres[*].fqdn)
}
output "postgres_port" {
  value = local.want_postgres ? local.postgres_port : null
}
output "postgres_server_name" {
  value = one(azurerm_postgresql_flexible_server.postgres[*].name)
}
output "postgres_connection_uri" {
  value = local.want_postgres ? format("postgresql://%s:%s@%s:%d/%s?sslmode=require",
    var.azure_db_username, local.db_password, azurerm_postgresql_flexible_server.postgres[0].fqdn,
    local.postgres_port, var.azure_db_name
  ) : null
  sensitive = true
}

# --- Cosmos DB for MongoDB vCore ---
# No mongodb_port: the address is a mongodb+srv:// one, resolved through DNS.
output "mongodb_host" {
  description = "MongoDB vCore cluster host (from its connection string)"
  value       = nonsensitive(local.mongodb_host)
}
output "mongodb_cluster_name" {
  value = one(azurerm_mongo_cluster.mongodb[*].name)
}
# What gen-data.sh hands gendata as MongoURI, used as is.
output "mongodb_uri" {
  description = "Complete mongodb+srv:// connection string, admin and password included"
  value       = local.mongodb_uri
  sensitive   = true
}
output "mongodb_connection_uri" {
  description = "Same as mongodb_uri, under the name every module uses for conn-info.sh --reveal"
  value       = local.mongodb_uri
  sensitive   = true
}

output "name_prefix" {
  description = "Name prefix, and the tofu workspace this environment lives in"
  value       = var.azure_name_prefix
}
