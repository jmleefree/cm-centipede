output "databases" {
  value = sort([for d in alicloud_db_database.target : d.data_base_name])
}
