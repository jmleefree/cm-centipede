#!/usr/bin/env bash
#
# alibaba-db-matrix.sh — Alibaba managed-DB version matrix
#
# The same matrix as aws-db-matrix.sh, with the network NCP needs and none of
# its console step:
#
#   1) Network — tofu/alibaba/network creates a VPC and one vSwitch in
#      ALIBABA_ZONE; every instance goes in it. No security group: the
#      instance's own IP whitelist (MATRIX_ALLOWED_CIDR) filters access.
#   2) Public endpoint — created through the API with the instance
#      (alicloud_db_connection, alicloud_mongodb_public_network_address), so
#      there is nothing to do in the console and no hook here.
#   3) Target databases — tofu/alibaba-target creates them through the RDS API
#      (alicloud_db_database), DBOwner on PostgreSQL.
#
# ⚠ Engines: mysql, mariadb, postgresql (ApsaraDB RDS) and mongodb (ApsaraDB for
#   MongoDB, a replica set). MongoDB connects as root, the replica set's only
#   account, and directly to the Primary's public address.
#
# ⚠ Versions are version lines (8.0, 10.6, 14.0, 7.0) - Alibaba picks the minor.
#   ./scripts/alibaba-db-versions.sh lists what ALIBABA_ZONE sells.
#
# ⚠ Cost: one instance per target version. MariaDB is sold as HighAvailability
#   only (a standby is billed too), and a MongoDB replica set has 3 nodes by
#   default (ALIBABA_MONGODB_NODES). They are destroyed when the run ends or is
#   interrupted with Ctrl-C; --keep-instance leaves them running. --cleanup
#   reclaims what an interruption left behind, from tofu state.
#
# ⚠ Requires:
#   - ./scripts/up.sh has started OpenBao and the tofu runner, with the Alibaba
#     keys registered. The runner must carry the Alibaba Cloud CLI, which the
#     MongoDB version and class check uses (docker compose build tofu-runner)
#   - cm-honeybee and cm-centipede running (checked in step 1)
#   - a running docker daemon, jq, curl
#
# Usage:
#   ./scripts/alibaba-db-matrix.sh
#   ./scripts/alibaba-db-matrix.sh --engines mysql --src-versions "8.0" --dst-versions "8.0"
#   ./scripts/alibaba-db-matrix.sh --cleanup
#
# Settings live in .env at the root of this folder (never committed).
#   Precedence: CLI option > real shell variable > .env > script default

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=./lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
load_env_file "$ENV_FILE"

CSP="alibaba"
CSP_TITLE="Alibaba"

# shellcheck source=./lib/db-matrix.sh
. "$SCRIPT_DIR/lib/db-matrix.sh"

matrix_main "$@"
