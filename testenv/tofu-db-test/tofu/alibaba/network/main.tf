# ---------------------------------------------------------------------------
# Alibaba network - the prerequisite for every Alibaba column.
#
#   Like NCP, a VPC and one vSwitch are created explicitly rather than relying
#   on a default network. tofu/alibaba/rdbms looks them up BY NAME, so this
#   module has to exist first; lib/tofu.sh applies it before the first column
#   and destroys it after the last one.
#
#   No security group is created. RDS and MongoDB instances are reached through
#   their public endpoint and filtered by their own IP whitelist (allowed_cidr
#   in tofu/alibaba/rdbms), not by a security group.
#
#   Every instance goes in this one vSwitch, so the zone has to sell every
#   engine the matrix runs (./scripts/alibaba-db-versions.sh lists the zones).
# ---------------------------------------------------------------------------
locals {
  vpc_name     = "${var.name_prefix}-vpc"
  vswitch_name = "${var.name_prefix}-vswitch"
}

resource "alicloud_vpc" "this" {
  vpc_name    = local.vpc_name
  cidr_block  = var.alibaba_vpc_cidr
  description = "cm-centipede version matrix"
}

resource "alicloud_vswitch" "this" {
  vpc_id       = alicloud_vpc.this.id
  vswitch_name = local.vswitch_name
  cidr_block   = cidrsubnet(var.alibaba_vpc_cidr, 8, 1) # 10.30.0.0/16 -> 10.30.1.0/24
  zone_id      = var.alibaba_zone
  description  = "cm-centipede version matrix"
}
