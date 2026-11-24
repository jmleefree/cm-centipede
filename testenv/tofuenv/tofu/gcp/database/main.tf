# ---------------------------------------------------------------------------
# GCP Database
#   - MySQL / PostgreSQL : Cloud SQL (public IP)
#   GCP has no managed MariaDB or MongoDB, so there are none.
#
#   No VPC: each instance gets a public IP, limited by its authorized networks
#   (allowed_cidr). Both run the Enterprise edition - Enterprise Plus, the
#   default for MySQL 8.4 and PostgreSQL 16+, refuses the small tiers - zonal,
#   with backups off and deletion protection off, as a test target needs.
#
#   A deleted instance name cannot be reused for about a week, so the names
#   carry a random suffix kept in state - one for both, so the names stay stable
#   when prepare.sh / teardown.sh --engine add or remove an engine.
#
#   MySQL log_bin_trust_function_creators is set on, so the fixture's functions
#   and triggers load whenever binary logging is on - see
#   dummy/docs/OPENTOFU_CSP별_DB파라미터_조사.md.
# ---------------------------------------------------------------------------
locals {
  db_password = data.vault_kv_secret_v2.db.data["GCP_DB_PASSWORD"]

  want_mysql    = contains(var.gcp_db_engines, "mysql")
  want_postgres = contains(var.gcp_db_engines, "postgres")

  suffix = random_string.suffix.result

  mysql_port    = 3306
  postgres_port = 5432

  # .env takes the version number alone, like the other CSPs; Cloud SQL names
  # the engine and the version together.
  mysql_database_version    = "MYSQL_${replace(var.gcp_mysql_version, ".", "_")}"
  postgres_database_version = "POSTGRES_${var.gcp_postgres_version}"
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

# ---------------------------------------------------------------------------
# Cloud SQL for MySQL
#   root is given the same password: Cloud SQL would otherwise leave root@%
#   without one, reachable from allowed_cidr.
# ---------------------------------------------------------------------------
resource "google_sql_database_instance" "mysql" {
  count = local.want_mysql ? 1 : 0

  name                = "${var.gcp_name_prefix}-mysql-${local.suffix}"
  region              = var.gcp_region
  database_version    = local.mysql_database_version
  root_password       = local.db_password
  deletion_protection = false

  settings {
    edition                     = "ENTERPRISE"
    tier                        = var.gcp_mysql_tier
    availability_type           = "ZONAL"
    disk_type                   = "PD_SSD"
    disk_size                   = var.gcp_mysql_storage_gb
    disk_autoresize             = false
    deletion_protection_enabled = false

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
      binary_log_enabled = false
    }

    database_flags {
      name  = "log_bin_trust_function_creators"
      value = "on"
    }
  }
}

resource "google_sql_database" "mysql" {
  count = local.want_mysql ? 1 : 0

  name      = var.gcp_db_name
  instance  = google_sql_database_instance.mysql[0].name
  charset   = "utf8mb4"
  collation = "utf8mb4_unicode_ci"
}

# ABANDON: the user goes with the instance, and dropping it on its own first
# would fail once it owns objects.
resource "google_sql_user" "mysql" {
  count = local.want_mysql ? 1 : 0

  name            = var.gcp_db_username
  instance        = google_sql_database_instance.mysql[0].name
  host            = "%"
  password        = local.db_password
  deletion_policy = "ABANDON"
}

# ---------------------------------------------------------------------------
# Cloud SQL for PostgreSQL
#   The admin is not a superuser on Cloud SQL; it is a member of
#   cloudsqlsuperuser, which owns the database, so gendata can create its
#   schema in it.
# ---------------------------------------------------------------------------
resource "google_sql_database_instance" "postgres" {
  count = local.want_postgres ? 1 : 0

  name                = "${var.gcp_name_prefix}-postgres-${local.suffix}"
  region              = var.gcp_region
  database_version    = local.postgres_database_version
  deletion_protection = false

  settings {
    edition                     = "ENTERPRISE"
    tier                        = var.gcp_postgres_tier
    availability_type           = "ZONAL"
    disk_type                   = "PD_SSD"
    disk_size                   = var.gcp_postgres_storage_gb
    disk_autoresize             = false
    deletion_protection_enabled = false

    ip_configuration {
      ipv4_enabled = true
      ssl_mode     = "ALLOW_UNENCRYPTED_AND_ENCRYPTED"
      authorized_networks {
        name  = "allowed-cidr"
        value = var.allowed_cidr
      }
    }

    backup_configuration {
      enabled = false
    }
  }
}

resource "google_sql_database" "postgres" {
  count = local.want_postgres ? 1 : 0

  name      = var.gcp_db_name
  instance  = google_sql_database_instance.postgres[0].name
  charset   = "UTF8"
  collation = "en_US.UTF8"
}

resource "google_sql_user" "postgres" {
  count = local.want_postgres ? 1 : 0

  name            = var.gcp_db_username
  instance        = google_sql_database_instance.postgres[0].name
  password        = local.db_password
  deletion_policy = "ABANDON"
}
