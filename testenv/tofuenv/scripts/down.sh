#!/usr/bin/env bash
# ==============================================================================
# down.sh — stop the containers
# ------------------------------------------------------------------------------
#   ./scripts/down.sh          # stop the containers (keep the OpenBao data volume)
#   ./scripts/down.sh --wipe   # also delete the volume (OpenBao data + credentials)
#                              #   -> the next start needs init + credential re-registration
#
#   --wipe also deletes the Transit key the tofu state is encrypted with, so it
#   is refused while an encrypted state exists: that state could never be read
#   again, and tofu would lose track of whatever it still holds at the CSP.
#   Destroy those environments first (teardown.sh), or set FORCE_WIPE=1. The
#   versions modules do not count: they create nothing and only cache a catalog
#   lookup, so their states are removed with the key and rebuilt on the next
#   *-db-versions.sh run.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

if [ "${1:-}" = "--wipe" ]; then
    ENCRYPTED_STATES="$(find "$ROOT_DIR/tofu" -name terraform.tfstate -type f -not -path '*/versions/*' 2>/dev/null | while read -r f; do
        jq -e 'has("encrypted_data")' "$f" >/dev/null 2>&1 && echo "  ${f#"$ROOT_DIR"/}"
    done || true)"
    if [ -n "$ENCRYPTED_STATES" ] && [ "${FORCE_WIPE:-}" != "1" ]; then
        echo -e "${RED}Refusing --wipe:${NC} these tofu states are encrypted with the OpenBao Transit key" >&2
        echo "  that --wipe deletes, and could never be read again:" >&2
        echo "$ENCRYPTED_STATES" >&2
        echo "" >&2
        echo "  Destroy those environments first (./scripts/teardown.sh; ./scripts/list.sh shows them)" >&2
        echo "  and delete their state files, or run with FORCE_WIPE=1 to wipe anyway." >&2
        exit 1
    fi
    echo -e "${RED}Deleting the volumes as well (OpenBao data and tokens will be lost).${NC}"
    docker compose down -v
    # The OpenBao data is a bind mount rather than a named volume, so remove it explicitly.
    rm -rf "$ROOT_DIR/container-volume/openbao-data"
    # The unseal key / root token file is worthless once the storage is gone.
    rm -f "$ROOT_DIR/init/openbao/secrets/openbao-init.json"
    # Encrypted with the key just deleted; rebuilt by the next *-db-versions.sh.
    rm -f "$ROOT_DIR"/tofu/*/versions/terraform.tfstate "$ROOT_DIR"/tofu/*/versions/terraform.tfstate.backup
    echo -e "${YELLOW}Removed the OpenBao storage and init secrets. The next up.sh will initialize from scratch.${NC}"
else
    docker compose down
fi
