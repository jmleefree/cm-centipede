# ---------------------------------------------------------------------------
# Alibaba Database
#   - MySQL / MariaDB / PostgreSQL : ApsaraDB RDS
#   - MongoDB                      : ApsaraDB for MongoDB (replica set)
#
#   Unlike NCP, the public endpoints are created through the API, so nothing has
#   to be done in the console: alicloud_db_connection gives each RDS instance its
#   public connection string, alicloud_mongodb_public_network_address the
#   MongoDB replica set. Access is limited by each instance's IP whitelist
#   (allowed_cidr); no security group is involved.
#
#   Each engine exists only when var.alibaba_db_engines names it, so prepare.sh /
#   teardown.sh --engine can add or remove one without touching the others.
#
#   No log_bin_trust_function_creators on MySQL or MariaDB. Alibaba does not let
#   it be modified: ModifyParameter answers InvalidParameters.Prohibited
#   ("Unsupported Parameters"), and the parameter is absent from
#   DescribeParameterTemplates for MySQL 8.0 (Basic and HighAvailability) and
#   MariaDB 10.6 (checked 2026-11-24, ap-northeast-2). A parameters block for it
#   fails the create after the instance has been launched.
# ---------------------------------------------------------------------------
locals {
  db_password = data.vault_kv_secret_v2.db.data["ALIBABA_DB_PASSWORD"]

  want_mysql    = contains(var.alibaba_db_engines, "mysql")
  want_mariadb  = contains(var.alibaba_db_engines, "mariadb")
  want_postgres = contains(var.alibaba_db_engines, "postgres")
  want_mongodb  = contains(var.alibaba_db_engines, "mongodb")
  want_rds      = local.want_mysql || local.want_mariadb || local.want_postgres

  mysql_category    = var.alibaba_mysql_category
  mariadb_category  = var.alibaba_mariadb_category
  postgres_category = var.alibaba_postgres_category

  # Public ports. Each instance has a host of its own, so mysql and mariadb can
  # both stay on 3306. The MongoDB port is Alibaba's (3717), read from the address.
  mysql_port    = 3306
  mariadb_port  = 3306
  postgres_port = 5432

  # MongoDB replica sets have one account, root; its password is the one set here.
  mongodb_username = "root"
}

# ---------------------------------------------------------------------------
# Look up what the network module created
# ---------------------------------------------------------------------------
data "alicloud_vpcs" "this" {
  name_regex = "^${var.alibaba_name_prefix}-vpc$"
}

data "alicloud_vswitches" "this" {
  vpc_id     = local.vpc_id
  name_regex = "^${var.alibaba_name_prefix}-vswitch$"
}

locals {
  vpc_id     = data.alicloud_vpcs.this.vpcs[0].id
  vswitch_id = data.alicloud_vswitches.this.vswitches[0].id
}

# ---------------------------------------------------------------------------
# Fail-fast instance class check
#   Lists the classes sold for the engine, version, edition, storage type and
#   zone together, and checks the requested one is among them at plan time,
#   instead of having the create call refuse it. An engine that is not wanted is
#   not looked up, and its precondition is never evaluated.
# ---------------------------------------------------------------------------
data "alicloud_db_instance_classes" "mysql" {
  count = local.want_mysql ? 1 : 0

  engine                   = "MySQL"
  engine_version           = var.alibaba_mysql_version
  category                 = local.mysql_category
  db_instance_storage_type = var.alibaba_db_storage_type
  zone_id                  = var.alibaba_zone
  instance_charge_type     = "PostPaid"
}

data "alicloud_db_instance_classes" "mariadb" {
  count = local.want_mariadb ? 1 : 0

  engine                   = "MariaDB"
  engine_version           = var.alibaba_mariadb_version
  category                 = local.mariadb_category
  db_instance_storage_type = var.alibaba_db_storage_type
  zone_id                  = var.alibaba_zone
  instance_charge_type     = "PostPaid"
}

data "alicloud_db_instance_classes" "postgres" {
  count = local.want_postgres ? 1 : 0

  engine                   = "PostgreSQL"
  engine_version           = var.alibaba_postgres_version
  category                 = local.postgres_category
  db_instance_storage_type = var.alibaba_db_storage_type
  zone_id                  = var.alibaba_zone
  instance_charge_type     = "PostPaid"
}

locals {
  mysql_class_ok    = try(contains(data.alicloud_db_instance_classes.mysql[0].ids, var.alibaba_mysql_instance_class), false)
  mariadb_class_ok  = try(contains(data.alicloud_db_instance_classes.mariadb[0].ids, var.alibaba_mariadb_instance_class), false)
  postgres_class_ok = try(contains(data.alicloud_db_instance_classes.postgres[0].ids, var.alibaba_postgres_instance_class), false)
}

# ---------------------------------------------------------------------------
# RDS MySQL
#   A Basic edition instance is single node. Any other edition gets its standby
#   in the same zone too (zone_id_slave_a), since the module has one vSwitch.
# ---------------------------------------------------------------------------
resource "alicloud_db_instance" "mysql" {
  count = local.want_mysql ? 1 : 0

  instance_name            = "${var.alibaba_name_prefix}-mysql"
  engine                   = "MySQL"
  engine_version           = var.alibaba_mysql_version
  instance_type            = var.alibaba_mysql_instance_class
  instance_storage         = var.alibaba_db_allocated_storage
  db_instance_storage_type = var.alibaba_db_storage_type
  category                 = local.mysql_category
  instance_charge_type     = "Postpaid"
  vpc_id                   = local.vpc_id
  vswitch_id               = local.vswitch_id
  zone_id                  = var.alibaba_zone
  zone_id_slave_a          = local.mysql_category == "Basic" ? null : var.alibaba_zone
  security_ips             = [var.allowed_cidr]
  deletion_protection      = false

  lifecycle {
    precondition {
      condition     = local.mysql_class_ok
      error_message = "TF_VAR_alibaba_mysql_instance_class='${var.alibaba_mysql_instance_class}' is not sold for MySQL ${var.alibaba_mysql_version} ${local.mysql_category} on ${var.alibaba_db_storage_type} in ${var.alibaba_zone}. Run ./scripts/alibaba-db-versions.sh mysql to list the classes."
    }
  }
}

resource "alicloud_db_account" "mysql" {
  count = local.want_mysql ? 1 : 0

  db_instance_id   = alicloud_db_instance.mysql[0].id
  account_name     = var.alibaba_db_username
  account_password = local.db_password
  account_type     = "Super"
}

resource "alicloud_db_database" "mysql" {
  count = local.want_mysql ? 1 : 0

  instance_id    = alicloud_db_instance.mysql[0].id
  data_base_name = var.alibaba_db_name
  character_set  = "utf8mb4"

  # The privileged account sees every database, so it needs no grant; it only
  # has to exist before the database is loaded.
  depends_on = [alicloud_db_account.mysql]
}

resource "alicloud_db_connection" "mysql" {
  count = local.want_mysql ? 1 : 0

  instance_id = alicloud_db_instance.mysql[0].id
  port        = local.mysql_port
}

# ---------------------------------------------------------------------------
# RDS MariaDB
# ---------------------------------------------------------------------------
resource "alicloud_db_instance" "mariadb" {
  count = local.want_mariadb ? 1 : 0

  instance_name            = "${var.alibaba_name_prefix}-mariadb"
  engine                   = "MariaDB"
  engine_version           = var.alibaba_mariadb_version
  instance_type            = var.alibaba_mariadb_instance_class
  instance_storage         = var.alibaba_db_allocated_storage
  db_instance_storage_type = var.alibaba_db_storage_type
  category                 = local.mariadb_category
  instance_charge_type     = "Postpaid"
  vpc_id                   = local.vpc_id
  vswitch_id               = local.vswitch_id
  zone_id                  = var.alibaba_zone
  zone_id_slave_a          = local.mariadb_category == "Basic" ? null : var.alibaba_zone
  security_ips             = [var.allowed_cidr]
  deletion_protection      = false

  lifecycle {
    precondition {
      condition     = local.mariadb_class_ok
      error_message = "TF_VAR_alibaba_mariadb_instance_class='${var.alibaba_mariadb_instance_class}' is not sold for MariaDB ${var.alibaba_mariadb_version} ${local.mariadb_category} on ${var.alibaba_db_storage_type} in ${var.alibaba_zone}. Run ./scripts/alibaba-db-versions.sh mariadb to list the classes."
    }
  }
}

resource "alicloud_db_account" "mariadb" {
  count = local.want_mariadb ? 1 : 0

  db_instance_id   = alicloud_db_instance.mariadb[0].id
  account_name     = var.alibaba_db_username
  account_password = local.db_password
  account_type     = "Super"
}

resource "alicloud_db_database" "mariadb" {
  count = local.want_mariadb ? 1 : 0

  instance_id    = alicloud_db_instance.mariadb[0].id
  data_base_name = var.alibaba_db_name
  character_set  = "utf8mb4"

  depends_on = [alicloud_db_account.mariadb]
}

resource "alicloud_db_connection" "mariadb" {
  count = local.want_mariadb ? 1 : 0

  instance_id = alicloud_db_instance.mariadb[0].id
  port        = local.mariadb_port
}

# ---------------------------------------------------------------------------
# RDS PostgreSQL
#   The database is created owned by the master account (DBOwner), so the
#   fixture's tables, views and functions can be created in it.
# ---------------------------------------------------------------------------
resource "alicloud_db_instance" "postgres" {
  count = local.want_postgres ? 1 : 0

  instance_name            = "${var.alibaba_name_prefix}-postgres"
  engine                   = "PostgreSQL"
  engine_version           = var.alibaba_postgres_version
  instance_type            = var.alibaba_postgres_instance_class
  instance_storage         = var.alibaba_db_allocated_storage
  db_instance_storage_type = var.alibaba_db_storage_type
  category                 = local.postgres_category
  instance_charge_type     = "Postpaid"
  vpc_id                   = local.vpc_id
  vswitch_id               = local.vswitch_id
  zone_id                  = var.alibaba_zone
  zone_id_slave_a          = local.postgres_category == "Basic" ? null : var.alibaba_zone
  security_ips             = [var.allowed_cidr]
  deletion_protection      = false

  lifecycle {
    precondition {
      condition     = local.postgres_class_ok
      error_message = "TF_VAR_alibaba_postgres_instance_class='${var.alibaba_postgres_instance_class}' is not sold for PostgreSQL ${var.alibaba_postgres_version} ${local.postgres_category} on ${var.alibaba_db_storage_type} in ${var.alibaba_zone}. Run ./scripts/alibaba-db-versions.sh postgresql to list the classes."
    }
  }
}

resource "alicloud_db_account" "postgres" {
  count = local.want_postgres ? 1 : 0

  db_instance_id   = alicloud_db_instance.postgres[0].id
  account_name     = var.alibaba_db_username
  account_password = local.db_password
  account_type     = "Super"
}

resource "alicloud_db_database" "postgres" {
  count = local.want_postgres ? 1 : 0

  instance_id       = alicloud_db_instance.postgres[0].id
  data_base_name    = var.alibaba_db_name
  character_set     = "UTF8,C,en_US.utf8"
  account_name      = alicloud_db_account.postgres[0].account_name
  account_privilege = "DBOwner"
}

resource "alicloud_db_connection" "postgres" {
  count = local.want_postgres ? 1 : 0

  instance_id = alicloud_db_instance.postgres[0].id
  port        = local.postgres_port
}

# ---------------------------------------------------------------------------
# ApsaraDB for MongoDB (replica set)
#   The root password is set on the instance itself. The public address gives
#   one endpoint per replica set member; the Primary's is used as the host, and
#   gendata connects with directConnection=true so the driver does not go on to
#   the members' private addresses.
# ---------------------------------------------------------------------------
resource "alicloud_mongodb_instance" "mongodb" {
  count = local.want_mongodb ? 1 : 0

  name                 = "${var.alibaba_name_prefix}-mongodb"
  engine_version       = var.alibaba_mongodb_version
  db_instance_class    = var.alibaba_mongodb_instance_class
  db_instance_storage  = var.alibaba_mongodb_storage
  storage_type         = var.alibaba_mongodb_storage_type
  storage_engine       = "WiredTiger"
  replication_factor   = var.alibaba_mongodb_replication_factor
  instance_charge_type = "PostPaid"
  network_type         = "VPC"
  vpc_id               = local.vpc_id
  vswitch_id           = local.vswitch_id
  zone_id              = var.alibaba_zone
  security_ip_list     = [var.allowed_cidr]
  account_password     = local.db_password
}

resource "alicloud_mongodb_public_network_address" "mongodb" {
  count = local.want_mongodb ? 1 : 0

  db_instance_id = alicloud_mongodb_instance.mongodb[0].id
}

locals {
  # An engine that is not wanted has no resource, and every value below is null.
  mongodb_primary = try(
    [for r in alicloud_mongodb_public_network_address.mongodb[0].replica_sets : r if r.replica_set_role == "Primary"][0],
    alicloud_mongodb_public_network_address.mongodb[0].replica_sets[0],
    null
  )
}
