output "instance_id" {
  value = aws_instance.vm.id
}

output "public_ip" {
  description = "Public IP of the VM"
  value       = aws_instance.vm.public_ip
}

output "ssh_user" {
  value = local.ssh_user
}

output "key_file" {
  description = "SSH private key path, relative to the tofuenv directory"
  value       = local.host_key_path
}

output "ssh_command" {
  description = "Ready-to-use SSH command"
  value       = "ssh -i ${local.host_key_path} ${local.ssh_user}@${aws_instance.vm.public_ip}"
}

output "data_path" {
  description = "Test data path (gendata filesystem basePath)"
  value       = var.aws_data_path
}
