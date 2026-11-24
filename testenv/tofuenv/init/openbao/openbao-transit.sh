#!/usr/bin/env bash
# ==============================================================================
# openbao-transit.sh — the Transit key that encrypts the tofu state
# ------------------------------------------------------------------------------
#   Enables the Transit secrets engine at transit/ and creates the key
#   `tofu-state` in it, both only when missing, so it is safe to run on every
#   ./scripts/up.sh. tofu-runner's TF_ENCRYPTION (docker-compose.yaml) asks this
#   key for a data key on every state write and to unwrap it on every read.
#
#   WHERE THE KEY LIVES
#   In OpenBao's storage (container-volume/openbao-data/logical/), encrypted by
#   its barrier like every other secret. It is not exportable and cannot be
#   deleted (deletion_allowed stays false), so losing it means losing OpenBao's
#   data or init/openbao/secrets/openbao-init.json - and with it every encrypted
#   state. Back the two up together.
#
#   Prerequisite: OpenBao is unsealed (openbao-init.sh / openbao-unseal.sh).
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INIT_OUTPUT="${INIT_OUTPUT:-$SCRIPT_DIR/secrets/openbao-init.json}"
VAULT_ADDR="${VAULT_ADDR:-http://localhost:38200}"
KEY_NAME="tofu-state"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

if [ ! -f "$INIT_OUTPUT" ]; then
    echo -e "${RED}Error: ${INIT_OUTPUT} not found. Run openbao-init.sh first.${NC}" >&2
    exit 1
fi
TOKEN="$(jq -r '.root_token' "$INIT_OUTPUT")"
H="X-Vault-Token: ${TOKEN}"

if ! MOUNTS="$(curl -sf -H "$H" "${VAULT_ADDR}/v1/sys/mounts")"; then
    echo -e "${RED}[openbao-transit]${NC} cannot list the secrets engines at ${VAULT_ADDR} (sealed, or the root token is stale?)" >&2
    exit 1
fi
if echo "$MOUNTS" | jq -e '."transit/"' >/dev/null 2>&1; then
    echo -e "${GREEN}[openbao-transit]${NC} Transit engine is already mounted at transit/."
else
    curl -sf -X POST -H "$H" -H "Content-Type: application/json" \
        -d '{"type": "transit"}' "${VAULT_ADDR}/v1/sys/mounts/transit" >/dev/null
    echo -e "${GREEN}[openbao-transit]${NC} Transit engine enabled at transit/."
fi

if curl -sf -H "$H" "${VAULT_ADDR}/v1/transit/keys/${KEY_NAME}" -o /dev/null; then
    echo -e "${GREEN}[openbao-transit]${NC} Key ${KEY_NAME} already exists."
else
    # aes256-gcm96, not exportable, not deletable: the defaults.
    curl -sf -X POST -H "$H" "${VAULT_ADDR}/v1/transit/keys/${KEY_NAME}" >/dev/null
    echo -e "${GREEN}[openbao-transit]${NC} Key ${KEY_NAME} created (encrypts the tofu state)."
    echo -e "  ${YELLOW}Back up container-volume/openbao-data/ together with ${INIT_OUTPUT}:${NC}"
    echo -e "  ${YELLOW}without both, an encrypted state cannot be read again.${NC}"
fi
