# ---------------------------------------------------------------------------
# Alibaba catalog lookup module - data sources only, it creates nothing.
# ---------------------------------------------------------------------------
#   Purpose: find the exact values to put into .env.
#     - TF_VAR_alibaba_zone                        : a zone offering ECS, RDS and MongoDB
#     - TF_VAR_alibaba_{mysql,mariadb,postgres}_version : RDS engine versions
#     - TF_VAR_alibaba_{mysql,mariadb,postgres}_instance_class : RDS classes, listed
#       for the version, edition and storage type .env sets, in TF_VAR_alibaba_zone
#     - TF_VAR_alibaba_instance_type / _image_name_regex : ECS type and image
#
#   The provider has no data source for MongoDB versions or classes; only the
#   zones that sell MongoDB are listed here. alibaba-db-versions.sh gets the
#   versions and classes through the Alibaba Cloud CLI instead.
#
#   Run: ./scripts/alibaba-db-versions.sh
# ---------------------------------------------------------------------------
locals {
  mysql_category    = var.alibaba_mysql_category
  mariadb_category  = var.alibaba_mariadb_category
  postgres_category = var.alibaba_postgres_category
}

# --- Zones ---------------------------------------------------------------------
data "alicloud_zones" "ecs" {
  available_resource_creation = "Instance"
}

data "alicloud_zones" "vswitch" {
  available_resource_creation = "VSwitch"
}

data "alicloud_db_zones" "mysql" {
  engine = "MySQL"
}

data "alicloud_db_zones" "mariadb" {
  engine = "MariaDB"
}

data "alicloud_db_zones" "postgres" {
  engine = "PostgreSQL"
}

data "alicloud_mongodb_zones" "this" {}

# --- RDS engine versions and editions, in TF_VAR_alibaba_zone --------------------
# Queried once per edition: without a category filter the data source keeps one
# edition per version (MySQL 8.0 came back as "cluster" alone although Basic is
# sold), so the editions a version offers are collected across these queries.
# Only the two editions the database module can create are asked about.
locals {
  rds_engine_queries = {
    for pair in setproduct(
      ["MySQL", "MariaDB", "PostgreSQL"], ["Basic", "HighAvailability"]
    ) : "${pair[0]}/${pair[1]}" => { engine = pair[0], category = pair[1] }
  }
}

data "alicloud_db_instance_engines" "this" {
  for_each = local.rds_engine_queries

  engine   = each.value.engine
  category = each.value.category
  zone_id  = var.alibaba_zone
}

# --- RDS classes for the version / edition / storage type .env sets ---------------
data "alicloud_db_instance_classes" "mysql" {
  engine                   = "MySQL"
  engine_version           = var.alibaba_mysql_version
  category                 = local.mysql_category
  db_instance_storage_type = var.alibaba_db_storage_type
  zone_id                  = var.alibaba_zone
  instance_charge_type     = "PostPaid"
}

data "alicloud_db_instance_classes" "mariadb" {
  engine                   = "MariaDB"
  engine_version           = var.alibaba_mariadb_version
  category                 = local.mariadb_category
  db_instance_storage_type = var.alibaba_db_storage_type
  zone_id                  = var.alibaba_zone
  instance_charge_type     = "PostPaid"
}

data "alicloud_db_instance_classes" "postgres" {
  engine                   = "PostgreSQL"
  engine_version           = var.alibaba_postgres_version
  category                 = local.postgres_category
  db_instance_storage_type = var.alibaba_db_storage_type
  zone_id                  = var.alibaba_zone
  instance_charge_type     = "PostPaid"
}

# --- ECS ---------------------------------------------------------------------------
# The full list runs to hundreds; the output keeps the small types only, which
# is what a test VM needs.
data "alicloud_instance_types" "this" {
  availability_zone    = var.alibaba_zone
  system_disk_category = var.alibaba_vm_disk_category
  instance_charge_type = "PostPaid"
  network_type         = "Vpc"
}

data "alicloud_images" "ubuntu" {
  name_regex = "^ubuntu"
  owners     = "system"
  os_type    = "linux"
}

locals {
  engine_names = { mysql = "MySQL", mariadb = "MariaDB", postgresql = "PostgreSQL" }

  # version -> editions, e.g. "8.0" -> "Basic, HighAvailability". The edition is
  # taken from the query, not from the result, for the reason given above.
  rds_versions = {
    for name, engine in local.engine_names : name => {
      for v, cats in {
        for pair in flatten([
          for key, q in local.rds_engine_queries : [
            for e in data.alicloud_db_instance_engines.this[key].instance_engines :
            { version = e.engine_version, category = q.category }
          ] if q.engine == engine
        ]) : pair.version => pair.category...
      } : v => join(", ", sort(distinct(cats)))
    }
  }

  # class -> storage range, e.g. "mysql.n2.medium.1" -> "20-32000 GB, step 5"
  rds_classes = {
    for name, ds in {
      mysql      = data.alicloud_db_instance_classes.mysql
      mariadb    = data.alicloud_db_instance_classes.mariadb
      postgresql = data.alicloud_db_instance_classes.postgres
      } : name => {
      for c in ds.instance_classes : c.instance_class => try(
        "${c.storage_range[0].min}-${c.storage_range[0].max} GB, step ${c.storage_range[0].step}", ""
      )
    }
  }
}
