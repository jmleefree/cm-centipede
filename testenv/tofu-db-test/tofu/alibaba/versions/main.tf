# ---------------------------------------------------------------------------
# Alibaba catalog lookup - data sources only, it creates nothing, it costs nothing.
# ---------------------------------------------------------------------------
#   Answers what the zone offers for the target axis of the matrix, so
#   ALIBABA_<engine>_DST_VERSIONS is filled in from the catalog rather than
#   guessed. Like NCP's, the RDS list is complete for what is asked: the
#   versions sold in ALIBABA_ZONE for the edition each engine is created with.
#
#   MongoDB is not here: the provider has no data source for its versions or
#   classes. lib/tofu.sh (_alibaba_mongodb_catalog) asks the Alibaba Cloud CLI
#   in the runner and adds the answer to this module's outputs.
# ---------------------------------------------------------------------------
locals {
  rds_engine = {
    mysql      = "MySQL"
    mariadb    = "MariaDB"
    postgresql = "PostgreSQL"
  }
  category = {
    mysql      = var.mysql_category
    mariadb    = var.mariadb_category
    postgresql = var.postgresql_category
  }
}

# Queried with the edition: without a category the data source keeps one
# edition per version (tofuenv saw MySQL 8.0 come back as "cluster" alone
# although Basic is sold).
data "alicloud_db_instance_engines" "this" {
  for_each = local.rds_engine

  engine   = each.value
  category = local.category[each.key]
  zone_id  = var.alibaba_zone
}

# Zones per engine, so a zone that does not sell one can be told apart from a
# version that is not sold.
data "alicloud_db_zones" "this" {
  for_each = local.rds_engine

  engine = each.value
}

data "alicloud_mongodb_zones" "this" {}

locals {
  rds_versions = {
    for name, ds in data.alicloud_db_instance_engines.this :
    name => sort(distinct([for e in ds.instance_engines : e.engine_version]))
  }
}
