# ---------------------------------------------------------------------------
# One managed Azure database = one column of the version matrix.
#
#   mysql / postgresql  Azure Database Flexible Server (public access)
#   mongodb             Azure Cosmos DB for MongoDB vCore
#   Azure Database for MariaDB was retired on 2025-09-19, so there is none.
#
#   Taken from tofuenv's tofu/azure/database, cut down to one engine. There is
#   no network module: the server uses public access, limited by a firewall rule
#   (allowed_cidr). Each column gets a resource group of its own, created and
#   deleted with it, so a destroy leaves nothing behind in the subscription.
#
#   Server names are DNS names, unique across Azure, so they carry a random
#   suffix kept in the column's state.
#
#   MySQL: log_bin_trust_function_creators is ON by default on Azure, and
#   require_secure_transport is ON - the matrix's prefer and my-target's
#   skip-verify both connect over TLS.
#   PostgreSQL: the admin is not a superuser but a member of azure_pg_admin,
#   which may create databases, so the cells use my-target / pg-target here as
#   on AWS.
#   MongoDB vCore: it hands out a mongodb+srv:// string and requires TLS. The
#   host output is the SRV name; lib/tofu.sh resolves it to the host and port
#   data-mig connects to, since data-mig assembles mongodb://host:port itself.
# ---------------------------------------------------------------------------
locals {
  db_password = data.vault_kv_secret_v2.db.data["AZURE_DB_PASSWORD"]

  is_mysql    = var.engine == "mysql"
  is_postgres = var.engine == "postgresql"
  is_mongo    = var.engine == "mongodb"

  # cptfm-mysql-8-0-21-ab12cd. Lowercase letters, digits and hyphens fit every
  # one of the three name rules (MySQL and PostgreSQL 3-63, MongoDB 3-40).
  base_name = "${var.name_prefix}-${var.engine}-${replace(var.engine_version, ".", "-")}"
  name      = "${local.base_name}-${random_string.suffix.result}"
  rg_name   = "${local.base_name}-rg"

  # Azure firewall rules take an IP range, not a CIDR: its first and last address.
  # 0.0.0.0/0 becomes 0.0.0.0 - 255.255.255.255, which is "every address" (unlike
  # 0.0.0.0 - 0.0.0.0, Azure's special "allow Azure services").
  firewall_start = cidrhost(var.allowed_cidr, 0)
  firewall_end   = cidrhost(var.allowed_cidr, -1)

  # The defaults match lib/tofu.sh (azure_sku), which always passes one. Not
  # B_Standard_B1ms: a PostgreSQL server on it was refused with SkuNotAvailable
  # in koreacentral although the capabilities API lists it (2026-11-25).
  sku = var.sku != "" ? var.sku : (local.is_postgres ? "GP_Standard_D2ds_v5" : "B_Standard_B2s")

  tags = {
    Project   = "cm-centipede"
    Matrix    = "db-migration-tofu-ver-matrix"
    ManagedBy = "opentofu"
    Engine    = var.engine
    Version   = var.engine_version
  }
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_resource_group" "this" {
  name     = local.rg_name
  location = var.azure_region
  tags     = local.tags
}

# ---------------------------------------------------------------------------
# MySQL Flexible Server
#   Azure picks the availability zone when none is given and may move it on a
#   failover, so zone is ignored rather than planned back every run.
# ---------------------------------------------------------------------------
resource "azurerm_mysql_flexible_server" "this" {
  count = local.is_mysql ? 1 : 0

  name                   = local.name
  resource_group_name    = azurerm_resource_group.this.name
  location               = azurerm_resource_group.this.location
  version                = var.engine_version
  sku_name               = local.sku
  administrator_login    = var.db_username
  administrator_password = local.db_password
  public_network_access  = "Enabled"
  tags                   = local.tags

  storage {
    size_gb = var.storage_gb
  }

  lifecycle {
    ignore_changes = [zone]
  }
}

resource "azurerm_mysql_flexible_database" "admin" {
  count = local.is_mysql ? 1 : 0

  name                = var.db_name
  resource_group_name = azurerm_resource_group.this.name
  server_name         = azurerm_mysql_flexible_server.this[0].name
  charset             = "utf8mb4"
  collation           = "utf8mb4_unicode_ci"
}

resource "azurerm_mysql_flexible_server_firewall_rule" "this" {
  count = local.is_mysql ? 1 : 0

  name                = "allowed-cidr"
  resource_group_name = azurerm_resource_group.this.name
  server_name         = azurerm_mysql_flexible_server.this[0].name
  start_ip_address    = local.firewall_start
  end_ip_address      = local.firewall_end
}

# ---------------------------------------------------------------------------
# PostgreSQL Flexible Server
# ---------------------------------------------------------------------------
resource "azurerm_postgresql_flexible_server" "this" {
  count = local.is_postgres ? 1 : 0

  name                          = local.name
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  version                       = var.engine_version
  sku_name                      = local.sku
  storage_mb                    = var.storage_gb * 1024
  administrator_login           = var.db_username
  administrator_password        = local.db_password
  public_network_access_enabled = true
  tags                          = local.tags

  lifecycle {
    ignore_changes = [zone]

    precondition {
      condition     = contains([32, 64, 128, 256, 512, 1024, 2048, 4095, 4096, 8192, 16384, 32767], var.storage_gb)
      error_message = "PostgreSQL storage must be one of the sizes Azure sells: 32, 64, 128, 256, 512, 1024, 2048, 4095, 4096, 8192, 16384, 32767 GB (AZURE_POSTGRESQL_STORAGE_GB)."
    }
  }
}

resource "azurerm_postgresql_flexible_server_database" "admin" {
  count = local.is_postgres ? 1 : 0

  name      = var.db_name
  server_id = azurerm_postgresql_flexible_server.this[0].id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "this" {
  count = local.is_postgres ? 1 : 0

  name             = "allowed-cidr"
  server_id        = azurerm_postgresql_flexible_server.this[0].id
  start_ip_address = local.firewall_start
  end_ip_address   = local.firewall_end
}

# ---------------------------------------------------------------------------
# Cosmos DB for MongoDB vCore
# ---------------------------------------------------------------------------
resource "azurerm_mongo_cluster" "this" {
  count = local.is_mongo ? 1 : 0

  name                   = local.name
  resource_group_name    = azurerm_resource_group.this.name
  location               = azurerm_resource_group.this.location
  version                = var.engine_version
  compute_tier           = var.mongodb_tier
  storage_size_in_gb     = var.storage_gb
  high_availability_mode = var.mongodb_high_availability
  shard_count            = 1
  administrator_username = var.db_username
  administrator_password = local.db_password
  public_network_access  = "Enabled"
  tags                   = local.tags
}

resource "azurerm_mongo_cluster_firewall_rule" "this" {
  count = local.is_mongo ? 1 : 0

  name             = "allowed-cidr"
  mongo_cluster_id = azurerm_mongo_cluster.this[0].id
  start_ip_address = local.firewall_start
  end_ip_address   = local.firewall_end
}

locals {
  # The SRV name of the mongodb+srv:// string: the part between @ and the path.
  # The string carries the password, so it is sensitive; the name alone is not.
  mongodb_uri      = try(azurerm_mongo_cluster.this[0].connection_strings[0].value, null)
  mongodb_srv_host = local.mongodb_uri == null ? null : nonsensitive(regex("@([^/?]+)", local.mongodb_uri)[0])

  host = (
    local.is_mysql ? try(azurerm_mysql_flexible_server.this[0].fqdn, null) : (
      local.is_postgres ? try(azurerm_postgresql_flexible_server.this[0].fqdn, null) :
      local.mongodb_srv_host
    )
  )
  # MongoDB's port comes with the SRV record, so it is resolved with the host.
  port = local.is_mysql ? 3306 : (local.is_postgres ? 5432 : null)
  id = (
    local.is_mysql ? try(azurerm_mysql_flexible_server.this[0].id, "") : (
      local.is_postgres ? try(azurerm_postgresql_flexible_server.this[0].id, "") :
      try(azurerm_mongo_cluster.this[0].id, "")
    )
  )
}
