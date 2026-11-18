output "instance_id" {
  description = "ECS instance ID"
  value       = alicloud_instance.vm.id
}

output "server_name" {
  value = alicloud_instance.vm.instance_name
}

output "public_ip" {
  description = "Public IP of the VM (gendata uses it as the SFTP target)"
  value       = alicloud_instance.vm.public_ip
}

output "private_ip" {
  value = alicloud_instance.vm.private_ip
}

output "volume_size" {
  description = "System disk size in GB, the one disk the test data lands on (gen-data.sh checks the dummy total against it)"
  # The variable rather than the instance attribute: an output is recorded at apply
  # time, so it is still what the VM was built with, and it is in GB for certain.
  value = var.alibaba_vm_volume_size
}

output "ssh_user" {
  description = "SSH account (Alibaba-provided images use root)"
  value       = local.ssh_user
}

output "key_file" {
  description = "SSH private key path, relative to the tofuenv directory"
  value       = local.host_key_path
}

output "key_pair_name" {
  value = alicloud_ecs_key_pair.vm.key_pair_name
}

output "ssh_command" {
  description = "Ready-to-use SSH command"
  value       = "ssh -i ${local.host_key_path} ${local.ssh_user}@${alicloud_instance.vm.public_ip}"
}

output "data_path" {
  description = "Test data path (gendata filesystem basePath)"
  value       = var.alibaba_data_path
}

output "image_id" {
  value = local.image_id
}

output "image_size" {
  description = "Image size in GB; the system disk cannot be smaller"
  value       = local.image_size
}

output "instance_type" {
  value = alicloud_instance.vm.instance_type
}

output "vpc_id" {
  value = local.vpc_id
}

output "vswitch_id" {
  value = local.vswitch_id
}

output "name_prefix" {
  description = "Name prefix, and the tofu workspace this environment lives in"
  value       = var.alibaba_name_prefix
}
