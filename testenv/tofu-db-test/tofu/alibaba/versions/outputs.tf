output "region" {
  value = var.alibaba_region
}

output "zone" {
  value = var.alibaba_zone
}

output "categories" {
  description = "The edition each RDS engine's versions were listed for"
  value       = local.category
}

output "zones" {
  description = "Zones selling each engine; ALIBABA_ZONE has to be in every one the matrix runs"
  value = merge(
    { for name, ds in data.alicloud_db_zones.this : name => sort(ds.ids) },
    { mongodb = sort(data.alicloud_mongodb_zones.this.ids) }
  )
}

# The bare version lists, keyed by the engine name the matrix uses. mongodb is
# added by lib/tofu.sh from the Alibaba Cloud CLI.
output "suggested_versions" {
  value = local.rds_versions
}
