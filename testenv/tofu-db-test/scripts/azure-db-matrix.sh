#!/usr/bin/env bash
#
# azure-db-matrix.sh — Azure managed-DB version matrix
#
# The same matrix as aws-db-matrix.sh, close to it in shape:
#
#   1) No network — each server uses public access with a firewall rule
#      (MATRIX_ALLOWED_CIDR). Each column lives in a resource group of its own,
#      deleted with it.
#   2) Target databases — my-target / pg-target, as on AWS: the Flexible Server
#      admin may CREATE DATABASE (on PostgreSQL it is a member of azure_pg_admin).
#
# ⚠ Engines: mysql, postgresql (Flexible Server) and mongodb (Cosmos DB for
#   MongoDB vCore). Azure Database for MariaDB was retired on 2025-09-19.
#
# ⚠ MongoDB vCore is not MongoDB itself:
#   - it hands out a mongodb+srv:// string; the matrix resolves its SRV record
#     to the host and port data-mig connects to (data-mig takes no SRV name)
#   - it requires TLS, so under the default TARGET_TLS_MODE=prefer its cells run
#     at require (not at disable, as MongoDB does on the other CSPs)
#   - its connection string asks for retrywrites=false, which data-mig does not
#     set; if vCore refuses retryable writes, the migration fails on its writes
#
# ⚠ Versions: MySQL 8.0.21 / 8.4, PostgreSQL a major (14), MongoDB 5.0-8.0.
#   ./scripts/azure-db-versions.sh lists what AZURE_REGION sells (ARM REST API).
#
# ⚠ Cost: one server per target version. They are destroyed when the run ends
#   or is interrupted with Ctrl-C; --keep-instance leaves them running.
#   --cleanup reclaims what an interruption left behind, from tofu state.
#
# ⚠ Requires:
#   - ./scripts/up.sh has started OpenBao and the tofu runner, with the Azure
#     service principal registered. The runner must carry dig (dnsutils), which
#     the MongoDB SRV lookup uses (docker compose build tofu-runner)
#   - the service principal may register Microsoft.DBforMySQL,
#     Microsoft.DBforPostgreSQL and Microsoft.DocumentDB on the subscription
#   - cm-honeybee and cm-centipede running (checked in step 1)
#
# Usage:
#   ./scripts/azure-db-matrix.sh
#   ./scripts/azure-db-matrix.sh --engines mysql --src-versions "8.0" --dst-versions "8.0.21"
#   ./scripts/azure-db-matrix.sh --cleanup
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

CSP="azure"
CSP_TITLE="Azure"

# shellcheck source=./lib/db-matrix.sh
. "$SCRIPT_DIR/lib/db-matrix.sh"

matrix_main "$@"
