# ---------------------------------------------------------------------------
# Common
#   Output names match the AWS and NCP modules so gendata can read them
#   CSP-agnostically. *_host is the public endpoint. An engine left out of
#   var.alibaba_db_engines has no resource, and all of its outputs are null.
# ---------------------------------------------------------------------------
output "db_name" {
  value = var.alibaba_db_name
}

# The two accounts are shown only for the engines that exist: tofu output leaves
# a null out, so a MongoDB-only environment lists mongodb_username alone instead
# of an RDS account nothing uses. gen-data.sh falls back to gendata's default
# for an empty db_username, and MongoDB is reached with mongodb_username anyway.
output "db_username" {
  description = "RDS master account (mysql, mariadb, postgresql); null without an RDS engine"
  value       = local.want_rds ? var.alibaba_db_username : null
}

output "mongodb_username" {
  description = "MongoDB account: replica sets have root only, so it differs from db_username. gen-data.sh passes it to gendata as MongoUser"
  value       = local.want_mongodb ? local.mongodb_username : null
}

output "db_password" {
  description = "DB master password, shared by RDS and MongoDB (read with: tofu output -raw db_password)"
  value       = local.db_password
  sensitive   = true
}

# --- MySQL (RDS) ---
output "mysql_host" {
  description = "MySQL public connection string"
  value       = one(alicloud_db_connection.mysql[*].connection_string)
}
output "mysql_port" {
  value = one(alicloud_db_connection.mysql[*].port)
}
output "mysql_instance_id" {
  value = one(alicloud_db_instance.mysql[*].id)
}
output "mysql_private_host" {
  description = "Private connection string for access from inside the VPC"
  value       = one(alicloud_db_instance.mysql[*].connection_string)
}
output "mysql_connection_uri" {
  value = local.want_mysql ? format("mysql://%s:%s@%s:%s/%s",
    var.alibaba_db_username, local.db_password, alicloud_db_connection.mysql[0].connection_string,
    alicloud_db_connection.mysql[0].port, var.alibaba_db_name
  ) : null
  sensitive = true
}

# --- MariaDB (RDS) ---
output "mariadb_host" {
  description = "MariaDB public connection string"
  value       = one(alicloud_db_connection.mariadb[*].connection_string)
}
output "mariadb_port" {
  value = one(alicloud_db_connection.mariadb[*].port)
}
output "mariadb_instance_id" {
  value = one(alicloud_db_instance.mariadb[*].id)
}
output "mariadb_private_host" {
  value = one(alicloud_db_instance.mariadb[*].connection_string)
}
output "mariadb_connection_uri" {
  value = local.want_mariadb ? format("mysql://%s:%s@%s:%s/%s",
    var.alibaba_db_username, local.db_password, alicloud_db_connection.mariadb[0].connection_string,
    alicloud_db_connection.mariadb[0].port, var.alibaba_db_name
  ) : null
  sensitive = true
}

# --- PostgreSQL (RDS) ---
output "postgres_host" {
  description = "PostgreSQL public connection string"
  value       = one(alicloud_db_connection.postgres[*].connection_string)
}
output "postgres_port" {
  value = one(alicloud_db_connection.postgres[*].port)
}
output "postgres_instance_id" {
  value = one(alicloud_db_instance.postgres[*].id)
}
output "postgres_private_host" {
  value = one(alicloud_db_instance.postgres[*].connection_string)
}
output "postgres_connection_uri" {
  value = local.want_postgres ? format("postgresql://%s:%s@%s:%s/%s",
    var.alibaba_db_username, local.db_password, alicloud_db_connection.postgres[0].connection_string,
    alicloud_db_connection.postgres[0].port, var.alibaba_db_name
  ) : null
  sensitive = true
}

# --- MongoDB (replica set) ---
output "mongodb_host" {
  description = "MongoDB public address of the Primary member"
  value       = try(local.mongodb_primary.connection_domain, null)
}
output "mongodb_port" {
  value = try(local.mongodb_primary.connection_port, null)
}
output "mongodb_instance_id" {
  value = one(alicloud_mongodb_instance.mongodb[*].id)
}
output "mongodb_public_members" {
  description = "Every replica set member's public address and role"
  value = local.want_mongodb ? [
    for r in alicloud_mongodb_public_network_address.mongodb[0].replica_sets :
    { role = r.replica_set_role, host = r.connection_domain, port = r.connection_port }
  ] : null
}
output "mongodb_connection_uri" {
  value = local.mongodb_primary == null ? null : format("mongodb://%s:%s@%s:%s/%s?authSource=admin&directConnection=true",
    local.mongodb_username, local.db_password, local.mongodb_primary.connection_domain,
    local.mongodb_primary.connection_port, var.alibaba_db_name
  )
  sensitive = true
}

# --- Network ---
output "vpc_id" {
  value = local.vpc_id
}
output "vswitch_id" {
  value = local.vswitch_id
}

output "name_prefix" {
  description = "Name prefix, and the tofu workspace this environment lives in"
  value       = var.alibaba_name_prefix
}
