# ---------------------------------------------------------------------------
# One managed Alibaba database = one column of the version matrix.
#
#   mysql / mariadb / postgresql  ApsaraDB RDS
#   mongodb                       ApsaraDB for MongoDB (replica set)
#
#   One of the two is created per apply. Unlike NCP, the public endpoint is
#   created through the API (alicloud_db_connection for RDS,
#   alicloud_mongodb_public_network_address for MongoDB), so no console step is
#   needed. Access is limited by the instance's IP whitelist (allowed_cidr).
#
#   Taken from tofuenv's tofu/alibaba/database, cut down to one engine:
#     - The instance class is checked at plan time against what is sold for the
#       engine, version, edition, storage type and zone together, so a wrong
#       class (or a version that does not exist) stops the apply before anything
#       is created. The provider has no such data source for MongoDB; the matrix
#       checks its version and class with the Alibaba Cloud CLI instead
#       (lib/tofu.sh, _alibaba_mongodb_catalog).
#
#   No log_bin_trust_function_creators. tofuenv sets it with a parameters block,
#   but Alibaba does not let it be modified: ModifyParameter answers
#   InvalidParameters.Prohibited ("Unsupported Parameters"), and the parameter
#   is absent from DescribeParameterTemplates for MySQL 8.0 (Basic and
#   HighAvailability) and MariaDB 10.6 (checked 2026-11-24, ap-northeast-2). The
#   create fails at that step after the instance has been launched. Whether the
#   seed's functions and triggers then restore (Error 1419 otherwise) is what
#   the migration and its validation report.
# ---------------------------------------------------------------------------
locals {
  db_password = data.vault_kv_secret_v2.db.data["ALIBABA_DB_PASSWORD"]

  is_mongo = var.engine == "mongodb"
  is_rds   = !local.is_mongo
  is_mysql = contains(["mysql", "mariadb"], var.engine)

  # The names the Alibaba API uses.
  rds_engine = {
    mysql      = "MySQL"
    mariadb    = "MariaDB"
    postgresql = "PostgreSQL"
  }

  # Defaults per engine, used when the matrix passes none. MariaDB is sold as
  # HighAvailability only (checked in ap-northeast-2a), so its class is a *.2c
  # one; the other two default to the single-node Basic edition.
  default_category = {
    mysql      = "Basic"
    mariadb    = "HighAvailability"
    postgresql = "Basic"
    mongodb    = ""
  }
  default_class = {
    mysql      = "mysql.n2.medium.1"
    mariadb    = "mariadb.n2.medium.2c"
    postgresql = "pg.n2.medium.1"
    mongodb    = "mdb.shard.4x.large.d"
  }
  category       = var.category != "" ? var.category : local.default_category[var.engine]
  instance_class = var.instance_class != "" ? var.instance_class : local.default_class[var.engine]

  # cptfm-mysql-8-0, cptfm-postgresql-14-0 - readable, and different per
  # column, so a column left behind by --keep-instance does not block the next.
  instance_name = "${var.name_prefix}-${var.engine}-${replace(var.engine_version, ".", "-")}"

  # Ports match the other CSPs' modules. MongoDB's public port is Alibaba's own
  # (3717), read from the address it is given.
  rds_port = var.engine == "postgresql" ? 5432 : 3306

  # A replica set has one account, root; its password is set on the instance.
  username = local.is_mongo ? "root" : var.db_username

  tags = {
    Project   = "cm-centipede"
    Matrix    = "db-migration-tofu-ver-matrix"
    ManagedBy = "opentofu"
    Engine    = var.engine
    Version   = var.engine_version
  }
}

# ---------------------------------------------------------------------------
# What the network module created, looked up by name.
# ---------------------------------------------------------------------------
data "alicloud_vpcs" "this" {
  name_regex = "^${var.name_prefix}-vpc$"
}

data "alicloud_vswitches" "this" {
  vpc_id     = local.vpc_id
  name_regex = "^${var.name_prefix}-vswitch$"
}

locals {
  vpc_id     = data.alicloud_vpcs.this.vpcs[0].id
  vswitch_id = data.alicloud_vswitches.this.vswitches[0].id
}

# ---------------------------------------------------------------------------
# Fail-fast class (and version) check, at plan time.
# ---------------------------------------------------------------------------
data "alicloud_db_instance_classes" "this" {
  count = local.is_rds ? 1 : 0

  engine                   = local.rds_engine[var.engine]
  engine_version           = var.engine_version
  category                 = local.category
  db_instance_storage_type = var.storage_type
  zone_id                  = var.alibaba_zone
  instance_charge_type     = "PostPaid"
}

locals {
  sold_classes = try(data.alicloud_db_instance_classes.this[0].ids, [])
}

# ---------------------------------------------------------------------------
# ApsaraDB RDS
#   A Basic edition instance is single node. HighAvailability gets its standby
#   in the same zone (zone_id_slave_a), since there is one vSwitch.
# ---------------------------------------------------------------------------
resource "alicloud_db_instance" "this" {
  count = local.is_rds ? 1 : 0

  instance_name            = local.instance_name
  engine                   = local.rds_engine[var.engine]
  engine_version           = var.engine_version
  instance_type            = local.instance_class
  instance_storage         = var.storage_gb
  db_instance_storage_type = var.storage_type
  category                 = local.category
  instance_charge_type     = "Postpaid"
  vpc_id                   = local.vpc_id
  vswitch_id               = local.vswitch_id
  zone_id                  = var.alibaba_zone
  zone_id_slave_a          = local.category == "Basic" ? null : var.alibaba_zone
  security_ips             = [var.allowed_cidr]
  deletion_protection      = false
  tags                     = local.tags

  lifecycle {
    precondition {
      condition = contains(local.sold_classes, local.instance_class)
      error_message = format(
        "Class %s is not sold for %s %s %s on %s in %s. Sold there: %s. Set ALIBABA_%s_INSTANCE_CLASS (or the version / ALIBABA_%s_CATEGORY), or list versions with ./scripts/alibaba-db-versions.sh.",
        local.instance_class, local.rds_engine[var.engine], var.engine_version, local.category,
        var.storage_type, var.alibaba_zone,
        length(local.sold_classes) > 0 ? join(", ", local.sold_classes) : "(nothing - the version or edition is not sold)",
        upper(var.engine), upper(var.engine)
      )
    }
  }
}

resource "alicloud_db_account" "this" {
  count = local.is_rds ? 1 : 0

  db_instance_id   = alicloud_db_instance.this[0].id
  account_name     = var.db_username
  account_password = local.db_password
  account_type     = "Super"
}

# The admin database the matrix connects to (ADMIN_DB). On PostgreSQL it is
# owned by the master account (DBOwner), as a cell's databases are.
resource "alicloud_db_database" "admin" {
  count = local.is_rds ? 1 : 0

  instance_id       = alicloud_db_instance.this[0].id
  data_base_name    = var.db_name
  character_set     = local.is_mysql ? "utf8mb4" : "UTF8,C,en_US.utf8"
  account_name      = local.is_mysql ? null : alicloud_db_account.this[0].account_name
  account_privilege = local.is_mysql ? null : "DBOwner"

  # The privileged account sees every database, so MySQL needs no grant; the
  # account only has to exist first.
  depends_on = [alicloud_db_account.this]
}

resource "alicloud_db_connection" "this" {
  count = local.is_rds ? 1 : 0

  instance_id = alicloud_db_instance.this[0].id
  port        = local.rds_port
}

# ---------------------------------------------------------------------------
# ApsaraDB for MongoDB (replica set)
#   The public address gives one endpoint per member; the Primary's is used.
#   data-mig always connects with directConnection=true, so the driver does not
#   go on to the members' private addresses.
# ---------------------------------------------------------------------------
resource "alicloud_mongodb_instance" "this" {
  count = local.is_mongo ? 1 : 0

  name                 = local.instance_name
  engine_version       = var.engine_version
  db_instance_class    = local.instance_class
  db_instance_storage  = var.mongodb_storage_gb
  storage_type         = var.mongodb_storage_type
  storage_engine       = "WiredTiger"
  replication_factor   = var.mongodb_nodes
  instance_charge_type = "PostPaid"
  network_type         = "VPC"
  vpc_id               = local.vpc_id
  vswitch_id           = local.vswitch_id
  zone_id              = var.alibaba_zone
  security_ip_list     = [var.allowed_cidr]
  account_password     = local.db_password
  tags                 = local.tags
}

resource "alicloud_mongodb_public_network_address" "this" {
  count = local.is_mongo ? 1 : 0

  db_instance_id = alicloud_mongodb_instance.this[0].id
}

locals {
  mongodb_primary = try(
    [for r in alicloud_mongodb_public_network_address.this[0].replica_sets : r if r.replica_set_role == "Primary"][0],
    alicloud_mongodb_public_network_address.this[0].replica_sets[0],
    null
  )

  host = local.is_mongo ? try(local.mongodb_primary.connection_domain, null) : try(alicloud_db_connection.this[0].connection_string, null)
  port = local.is_mongo ? try(tonumber(local.mongodb_primary.connection_port), null) : try(tonumber(alicloud_db_connection.this[0].port), local.rds_port)
  id   = local.is_mongo ? try(alicloud_mongodb_instance.this[0].id, "") : try(alicloud_db_instance.this[0].id, "")
}
