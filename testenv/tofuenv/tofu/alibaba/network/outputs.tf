output "vpc_id" {
  description = "ID of the created VPC"
  value       = alicloud_vpc.this.id
}

output "vpc_name" {
  value = alicloud_vpc.this.vpc_name
}

output "vpc_cidr" {
  value = alicloud_vpc.this.cidr_block
}

output "vswitch_id" {
  description = "ID of the vSwitch (the vm and database modules look it up by name)"
  value       = alicloud_vswitch.this.id
}

output "vswitch_name" {
  value = alicloud_vswitch.this.vswitch_name
}

output "vswitch_cidr" {
  value = alicloud_vswitch.this.cidr_block
}

output "zone" {
  value = alicloud_vswitch.this.zone_id
}

output "server_sg_id" {
  description = "ID of the security group used by servers (VMs)"
  value       = alicloud_security_group.server.id
}

output "server_sg_name" {
  value = alicloud_security_group.server.security_group_name
}

output "name_prefix" {
  description = "Name prefix, and the tofu workspace this environment lives in"
  value       = var.alibaba_name_prefix
}
