output "zones" {
  description = "Zones per service; TF_VAR_alibaba_zone must be in ecs, vswitch and every engine used"
  value = {
    ecs        = sort(data.alicloud_zones.ecs.ids)
    vswitch    = sort(data.alicloud_zones.vswitch.ids)
    mysql      = sort(data.alicloud_db_zones.mysql.ids)
    mariadb    = sort(data.alicloud_db_zones.mariadb.ids)
    postgresql = sort(data.alicloud_db_zones.postgres.ids)
    mongodb    = sort(data.alicloud_mongodb_zones.this.ids)
  }
}

output "rds_versions" {
  description = "engine -> { version -> editions (Basic / HighAvailability) } in TF_VAR_alibaba_zone"
  value       = local.rds_versions
}

output "rds_classes" {
  description = "engine -> { class -> storage range } for the version, edition and storage type .env sets"
  value       = local.rds_classes
}

output "rds_class_filter" {
  description = "What rds_classes was listed for"
  value = {
    zone         = var.alibaba_zone
    storage_type = var.alibaba_db_storage_type
    mysql        = "${var.alibaba_mysql_version} ${local.mysql_category}"
    mariadb      = "${var.alibaba_mariadb_version} ${local.mariadb_category}"
    postgresql   = "${var.alibaba_postgres_version} ${local.postgres_category}"
  }
}

output "instance_types" {
  description = "ECS instance types in TF_VAR_alibaba_zone with up to 8 vCPUs: id -> vCPU / memory"
  value = {
    for t in data.alicloud_instance_types.this.instance_types :
    t.id => "${t.cpu_core_count} vCPU / ${t.memory_size} GB" if t.cpu_core_count <= 8
  }
}

output "images" {
  description = "Ubuntu system images: name -> size and OS. The system disk cannot be smaller than the size"
  value       = { for i in data.alicloud_images.ubuntu.images : i.name => "${i.size} GB, ${i.os_name_en}" }
}
