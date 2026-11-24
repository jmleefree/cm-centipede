output "instance_id" {
  description = "VM instance ID"
  value       = google_compute_instance.vm.instance_id
}

output "server_name" {
  value = google_compute_instance.vm.name
}

output "public_ip" {
  description = "Static external IP of the VM (gendata uses it as the SFTP target)"
  value       = google_compute_address.this.address
}

output "private_ip" {
  value = google_compute_instance.vm.network_interface[0].network_ip
}

output "volume_size" {
  description = "Boot disk size in GB, the one disk the test data lands on (gen-data.sh checks the dummy total against it)"
  # The variable rather than the disk attribute: an output is recorded at apply
  # time, so it is still what the VM was built with.
  value = var.gcp_vm_volume_size
}

output "ssh_user" {
  description = "SSH account, created from the ssh-keys metadata"
  value       = local.ssh_user
}

output "key_file" {
  description = "SSH private key path, relative to the tofuenv directory"
  value       = local.host_key_path
}

output "ssh_command" {
  description = "Ready-to-use SSH command"
  value       = "ssh -i ${local.host_key_path} ${local.ssh_user}@${google_compute_address.this.address}"
}

output "data_path" {
  description = "Test data path (gendata filesystem basePath)"
  value       = var.gcp_data_path
}

output "machine_type" {
  value = google_compute_instance.vm.machine_type
}

output "image" {
  description = "The image the boot disk was created from (the latest of the family at apply time)"
  value       = data.google_compute_image.ubuntu.name
}

output "zone" {
  value = google_compute_instance.vm.zone
}

output "vpc_name" {
  description = "VPC holding the VM; teardown deletes it with the VM"
  value       = google_compute_network.this.name
}

output "name_prefix" {
  description = "Name prefix, and the tofu workspace this environment lives in"
  value       = var.gcp_name_prefix
}
