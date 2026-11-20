output "instance_id" {
  description = "VM resource ID"
  value       = azurerm_linux_virtual_machine.vm.id
}

output "server_name" {
  value = azurerm_linux_virtual_machine.vm.name
}

output "public_ip" {
  description = "Public IP of the VM (gendata uses it as the SFTP target)"
  value       = azurerm_public_ip.this.ip_address
}

output "private_ip" {
  value = azurerm_linux_virtual_machine.vm.private_ip_address
}

output "volume_size" {
  description = "OS disk size in GB, the one disk the test data lands on (gen-data.sh checks the dummy total against it)"
  # The variable rather than the VM attribute: an output is recorded at apply
  # time, so it is still what the VM was built with, and it is in GB for certain.
  value = var.azure_vm_volume_size
}

output "ssh_user" {
  description = "SSH account (Azure does not allow root as the admin)"
  value       = local.ssh_user
}

output "key_file" {
  description = "SSH private key path, relative to the tofuenv directory"
  value       = local.host_key_path
}

output "ssh_command" {
  description = "Ready-to-use SSH command"
  value       = "ssh -i ${local.host_key_path} ${local.ssh_user}@${azurerm_public_ip.this.ip_address}"
}

output "data_path" {
  description = "Test data path (gendata filesystem basePath)"
  value       = var.azure_data_path
}

output "vm_size" {
  value = azurerm_linux_virtual_machine.vm.size
}

output "image" {
  value = "Canonical:${var.azure_image_offer}:${var.azure_image_sku}:latest"
}

output "resource_group" {
  description = "Resource group holding the VM and its network; teardown deletes it"
  value       = azurerm_resource_group.this.name
}

output "name_prefix" {
  description = "Name prefix, and the tofu workspace this environment lives in"
  value       = var.azure_name_prefix
}
