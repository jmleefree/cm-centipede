# ---------------------------------------------------------------------------
# Alibaba network (prerequisite module)
#   A default VPC exists only in regions where one was created, so the VPC,
#   vSwitch and security group are created explicitly, as on NCP. The vm and
#   database modules look these up by name through data sources, so their state
#   stays separate but this module must be applied first.
#
#   One vSwitch, in one zone: ECS, RDS and MongoDB all attach to it.
# ---------------------------------------------------------------------------
locals {
  vpc_name     = "${var.alibaba_name_prefix}-vpc"
  vswitch_name = "${var.alibaba_name_prefix}-vswitch"
  sg_name      = "${var.alibaba_name_prefix}-server-sg"
}

resource "alicloud_vpc" "this" {
  vpc_name    = local.vpc_name
  cidr_block  = var.alibaba_vpc_cidr
  description = "cm-centipede migration test environment"
}

resource "alicloud_vswitch" "this" {
  vpc_id       = alicloud_vpc.this.id
  vswitch_name = local.vswitch_name
  cidr_block   = cidrsubnet(var.alibaba_vpc_cidr, 8, 1) # e.g. 10.20.0.0/16 -> 10.20.1.0/24
  zone_id      = var.alibaba_zone
  description  = "cm-centipede migration test environment"
}

# ---------------------------------------------------------------------------
# Security group for servers (the VM).
#   Outbound is open by default on an Alibaba security group, so only inbound
#   rules are declared. A rule in a VPC security group must be nic_type intranet.
#   The managed databases do not use it: RDS and MongoDB take their own IP
#   whitelists in the database module.
# ---------------------------------------------------------------------------
resource "alicloud_security_group" "server" {
  security_group_name = local.sg_name
  description         = "cm-centipede migration test servers (SSH)"
  vpc_id              = alicloud_vpc.this.id
}

resource "alicloud_security_group_rule" "ssh" {
  security_group_id = alicloud_security_group.server.id
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  port_range        = "22/22"
  cidr_ip           = var.allowed_cidr
  policy            = "accept"
  priority          = 1
  description       = "SSH"
}
