# ---------------------------------------------------------------------------
# Azure Database
#   - MySQL / PostgreSQL : Azure Database Flexible Server (public access)
#   - MongoDB            : Azure Cosmos DB for MongoDB vCore
#   Azure Database for MariaDB was retired on 2025-09-19, so there is none.
#
#   Everything lives in one resource group, <prefix>-database-rg, which teardown
#   deletes with all of it. No VNet: the servers use public access, limited by
#   their firewall rules (allowed_cidr), and reached over their public endpoints.
#
#   Server names are DNS names, unique across Azure, so they carry a random
#   suffix kept in state - one for all three, so the names stay stable when
#   prepare.sh / teardown.sh --engine add or remove an engine.
#
#   MySQL log_bin_trust_function_creators is ON by default on Azure (binary
#   logging is always on there), so the fixture's functions and triggers load
#   with no parameter set - see dummy/docs/OPENTOFU_CSP별_DB파라미터_조사.md.
# ---------------------------------------------------------------------------
locals {
  db_password = data.vault_kv_secret_v2.db.data["AZURE_DB_PASSWORD"]

  want_mysql    = contains(var.azure_db_engines, "mysql")
  want_postgres = contains(var.azure_db_engines, "postgres")
  want_mongodb  = contains(var.azure_db_engines, "mongodb")

  rg_name = "${var.azure_name_prefix}-database-rg"
  suffix  = random_string.suffix.result

  mysql_port    = 3306
  postgres_port = 5432

  # Azure firewall rules take an IP range, not a CIDR: its first and last address.
  # 0.0.0.0/0 becomes 0.0.0.0 - 255.255.255.255, which is "every address" (unlike
  # 0.0.0.0 - 0.0.0.0, Azure's special "allow Azure services").
  firewall_start = cidrhost(var.allowed_cidr, 0)
  firewall_end   = cidrhost(var.allowed_cidr, -1)
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_resource_group" "this" {
  name     = local.rg_name
  location = var.azure_region
}

# ---------------------------------------------------------------------------
# MySQL Flexible Server
#   Azure picks the availability zone when none is given and may move it on a
#   failover, so zone is ignored rather than planned back every run.
# ---------------------------------------------------------------------------
resource "azurerm_mysql_flexible_server" "mysql" {
  count = local.want_mysql ? 1 : 0

  name                   = "${var.azure_name_prefix}-mysql-${local.suffix}"
  resource_group_name    = azurerm_resource_group.this.name
  location               = azurerm_resource_group.this.location
  version                = var.azure_mysql_version
  sku_name               = var.azure_mysql_sku
  administrator_login    = var.azure_db_username
  administrator_password = local.db_password
  public_network_access  = "Enabled"

  storage {
    size_gb = var.azure_mysql_storage_gb
  }

  lifecycle {
    ignore_changes = [zone]
  }
}

resource "azurerm_mysql_flexible_database" "mysql" {
  count = local.want_mysql ? 1 : 0

  name                = var.azure_db_name
  resource_group_name = azurerm_resource_group.this.name
  server_name         = azurerm_mysql_flexible_server.mysql[0].name
  charset             = "utf8mb4"
  collation           = "utf8mb4_unicode_ci"
}

resource "azurerm_mysql_flexible_server_firewall_rule" "mysql" {
  count = local.want_mysql ? 1 : 0

  name                = "allowed-cidr"
  resource_group_name = azurerm_resource_group.this.name
  server_name         = azurerm_mysql_flexible_server.mysql[0].name
  start_ip_address    = local.firewall_start
  end_ip_address      = local.firewall_end
}

# ---------------------------------------------------------------------------
# PostgreSQL Flexible Server
#   The admin is not a superuser on Azure; it is a member of azure_pg_admin,
#   which is enough for gendata to create its schema in the database.
# ---------------------------------------------------------------------------
resource "azurerm_postgresql_flexible_server" "postgres" {
  count = local.want_postgres ? 1 : 0

  name                          = "${var.azure_name_prefix}-postgres-${local.suffix}"
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  version                       = var.azure_postgres_version
  sku_name                      = var.azure_postgres_sku
  storage_mb                    = var.azure_postgres_storage_gb * 1024
  administrator_login           = var.azure_db_username
  administrator_password        = local.db_password
  public_network_access_enabled = true

  lifecycle {
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "postgres" {
  count = local.want_postgres ? 1 : 0

  name      = var.azure_db_name
  server_id = azurerm_postgresql_flexible_server.postgres[0].id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "postgres" {
  count = local.want_postgres ? 1 : 0

  name             = "allowed-cidr"
  server_id        = azurerm_postgresql_flexible_server.postgres[0].id
  start_ip_address = local.firewall_start
  end_ip_address   = local.firewall_end
}

# ---------------------------------------------------------------------------
# Cosmos DB for MongoDB vCore
#   It hands out a mongodb+srv:// connection string with TLS required, which
#   gendata cannot assemble from a host and port, so the module outputs it as
#   mongodb_uri and gen-data.sh passes it on as MongoURI.
# ---------------------------------------------------------------------------
resource "azurerm_mongo_cluster" "mongodb" {
  count = local.want_mongodb ? 1 : 0

  name                   = "${var.azure_name_prefix}-mongo-${local.suffix}"
  resource_group_name    = azurerm_resource_group.this.name
  location               = azurerm_resource_group.this.location
  version                = var.azure_mongodb_version
  compute_tier           = var.azure_mongodb_tier
  storage_size_in_gb     = var.azure_mongodb_storage_gb
  high_availability_mode = var.azure_mongodb_high_availability
  shard_count            = 1
  administrator_username = var.azure_db_username
  administrator_password = local.db_password
  public_network_access  = "Enabled"
}

resource "azurerm_mongo_cluster_firewall_rule" "mongodb" {
  count = local.want_mongodb ? 1 : 0

  name             = "allowed-cidr"
  mongo_cluster_id = azurerm_mongo_cluster.mongodb[0].id
  start_ip_address = local.firewall_start
  end_ip_address   = local.firewall_end
}

locals {
  # The first connection string, with the admin and password filled in by the
  # provider. Its host is pulled out for display: the part between @ and the path.
  mongodb_uri  = try(azurerm_mongo_cluster.mongodb[0].connection_strings[0].value, null)
  mongodb_host = try(regex("@([^/?]+)", local.mongodb_uri)[0], null)
}
