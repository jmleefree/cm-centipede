# ---------------------------------------------------------------------------
# A cell's target databases on Alibaba RDS, created through the CSP API.
#
#   Like tofu/ncp-target, and unlike my-target / pg-target, nothing connects to
#   the database here: alicloud_db_database creates it through the RDS API,
#   addressed by the instance ID the column's tofu/alibaba/rdbms reports. On
#   PostgreSQL the API takes the owner as well (DBOwner), so a cell's database
#   belongs to the master account from the start - the same way tofuenv creates
#   its Alibaba databases.
#
#   MongoDB never reaches this module: it has no CREATE DATABASE, a database
#   begins with its first write.
# ---------------------------------------------------------------------------
locals {
  is_mysql = contains(["mysql", "mariadb"], var.engine)
}

resource "alicloud_db_database" "target" {
  for_each = toset(var.databases)

  instance_id    = var.instance_no
  data_base_name = each.value
  character_set  = local.is_mysql ? "utf8mb4" : "UTF8,C,en_US.utf8"

  # PostgreSQL only: the owner. The privileged MySQL account sees every
  # database already and needs no grant.
  account_name      = local.is_mysql ? null : var.owner
  account_privilege = local.is_mysql ? null : "DBOwner"

  lifecycle {
    precondition {
      condition     = local.is_mysql || length(var.owner) > 0
      error_message = "owner is required for PostgreSQL: the CSP API takes it at creation time."
    }
  }
}
