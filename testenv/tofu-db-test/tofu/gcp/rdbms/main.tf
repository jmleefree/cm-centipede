# ---------------------------------------------------------------------------
# One managed GCP database = one column of the version matrix.
#
#   mysql / postgresql  Cloud SQL (public IP)
#   GCP has no managed MariaDB or MongoDB, so there are none.
#
#   Taken from tofuenv's tofu/gcp/database, cut down to one engine. There is no
#   network module: the instance gets a public IP, limited by an authorized
#   network (allowed_cidr). It runs the Enterprise edition - Enterprise Plus,
#   the default for MySQL 8.4 and PostgreSQL 16+, refuses the small tiers -
#   zonal, with backups off and deletion protection off, as a test target needs.
#
#   A deleted instance name cannot be reused for about a week, and the matrix
#   creates and destroys the same column again and again, so the name carries a
#   random suffix kept in the column's state.
#
#   MySQL: log_bin_trust_function_creators is set on, so the seed's functions
#   and triggers restore whenever binary logging is on.
#   Both: the admin is a member of cloudsqlsuperuser, which may create
#   databases, so the cells use my-target / pg-target here as on AWS.
# ---------------------------------------------------------------------------
locals {
  db_password = data.vault_kv_secret_v2.db.data["GCP_DB_PASSWORD"]

  is_mysql    = var.engine == "mysql"
  is_postgres = var.engine == "postgresql"

  # .env takes the version number alone, like the other CSPs; Cloud SQL names
  # the engine and the version together (MYSQL_8_4, POSTGRES_16).
  database_version = local.is_mysql ? "MYSQL_${replace(var.engine_version, ".", "_")}" : "POSTGRES_${var.engine_version}"

  # cptfm-mysql-8-4-ab12cd. Cloud SQL names are lowercase letters, digits and
  # hyphens, starting with a letter, 98 characters at most.
  name = "${var.name_prefix}-${var.engine}-${replace(var.engine_version, ".", "-")}-${random_string.suffix.result}"

  port = local.is_mysql ? 3306 : 5432

  labels = {
    project    = "cm-centipede"
    matrix     = "db-migration-tofu-ver-matrix"
    managed-by = "opentofu"
    engine     = var.engine
    version    = replace(var.engine_version, ".", "-")
  }
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

# MySQL only: root is given the same password - Cloud SQL would otherwise leave
# root@% without one, reachable from allowed_cidr.
resource "google_sql_database_instance" "this" {
  name                = local.name
  region              = var.gcp_region
  database_version    = local.database_version
  root_password       = local.is_mysql ? local.db_password : null
  deletion_protection = false

  settings {
    edition                     = "ENTERPRISE"
    tier                        = var.tier
    availability_type           = "ZONAL"
    disk_type                   = "PD_SSD"
    disk_size                   = var.storage_gb
    disk_autoresize             = false
    deletion_protection_enabled = false
    user_labels                 = local.labels

    ip_configuration {
      ipv4_enabled = true
      ssl_mode     = "ALLOW_UNENCRYPTED_AND_ENCRYPTED"
      authorized_networks {
        name  = "allowed-cidr"
        value = var.allowed_cidr
      }
    }

    backup_configuration {
      enabled            = false
      binary_log_enabled = local.is_mysql ? false : null
    }

    dynamic "database_flags" {
      for_each = local.is_mysql ? [1] : []
      content {
        name  = "log_bin_trust_function_creators"
        value = "on"
      }
    }
  }
}

# The admin database the matrix connects to (ADMIN_DB).
resource "google_sql_database" "admin" {
  name      = var.db_name
  instance  = google_sql_database_instance.this.name
  charset   = local.is_mysql ? "utf8mb4" : "UTF8"
  collation = local.is_mysql ? "utf8mb4_unicode_ci" : "en_US.UTF8"
}

# ABANDON: the user goes with the instance, and dropping it on its own first
# would fail once it owns objects.
resource "google_sql_user" "admin" {
  name            = var.db_username
  instance        = google_sql_database_instance.this.name
  host            = local.is_mysql ? "%" : null
  password        = local.db_password
  deletion_policy = "ABANDON"
}
