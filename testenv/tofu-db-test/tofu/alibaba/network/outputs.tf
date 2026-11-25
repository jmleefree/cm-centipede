output "vpc_id" {
  value = alicloud_vpc.this.id
}

output "vpc_name" {
  description = "Read by lib/tofu.sh to tell whether the network was created under the current name prefix"
  value       = alicloud_vpc.this.vpc_name
}

output "vswitch_id" {
  value = alicloud_vswitch.this.id
}

output "vswitch_name" {
  value = alicloud_vswitch.this.vswitch_name
}

output "zone" {
  value = alicloud_vswitch.this.zone_id
}
