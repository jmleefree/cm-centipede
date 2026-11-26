#!/usr/bin/env bash
#
# gcp-db-matrix.sh — GCP managed-DB version matrix
#
# The same matrix as aws-db-matrix.sh, close to it in shape:
#
#   1) No network — each Cloud SQL instance gets a public IP with an authorized
#      network (MATRIX_ALLOWED_CIDR).
#   2) Target databases — my-target / pg-target, as on AWS: the admin is a
#      member of cloudsqlsuperuser and may CREATE DATABASE.
#
# ⚠ Engines: mysql, postgresql (Cloud SQL, Enterprise edition, zonal). GCP has
#   no managed MariaDB or MongoDB.
#
# ⚠ Versions are numbers: MySQL 8.0 / 8.4, PostgreSQL a major (16).
#   ./scripts/gcp-db-versions.sh lists what Cloud SQL offers (sqladmin REST API).
#
# ⚠ Names: a deleted Cloud SQL instance name cannot be reused for about a week,
#   so each instance carries a random suffix kept in tofu state.
#
# ⚠ Cost: one instance per target version (db-custom-1-3840 by default). They
#   are destroyed when the run ends or is interrupted with Ctrl-C;
#   --keep-instance leaves them running. --cleanup reclaims what an
#   interruption left behind, from tofu state.
#
# ⚠ Requires:
#   - ./scripts/up.sh has started OpenBao and the tofu runner, with the GCP
#     service account registered
#   - the Cloud SQL Admin API enabled on the project
#     (gcloud services enable sqladmin.googleapis.com), and the service account
#     allowed to manage Cloud SQL (roles/cloudsql.admin, or Editor)
#   - cm-honeybee and cm-centipede running (checked in step 1)
#
# Usage:
#   ./scripts/gcp-db-matrix.sh
#   ./scripts/gcp-db-matrix.sh --engines mysql --src-versions "8.0" --dst-versions "8.0"
#   ./scripts/gcp-db-matrix.sh --cleanup
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

CSP="gcp"
CSP_TITLE="GCP"

# shellcheck source=./lib/db-matrix.sh
. "$SCRIPT_DIR/lib/db-matrix.sh"

matrix_main "$@"
