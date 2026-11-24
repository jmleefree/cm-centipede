#!/usr/bin/env bash
#
# down.sh — stop the matrix stack
#
#   Containers only. OpenBao's storage (container-volume/openbao-data) and its
#   unseal key (init/openbao/secrets/) are kept, so the next ./scripts/up.sh
#   unseals rather than initializes.
#
# ⚠ This script deletes no CSP resources. The managed instances the matrix
#   creates are destroyed by the matrix itself when it ends. If an interruption
#   left something behind, reclaim it before taking the stack down:
#
#     ./scripts/aws-db-matrix.sh --cleanup     # destroy everything left in tofu state
#
# ⚠ It does not remove source containers either. The matrix removes them per
#   cell, but --keep-on-fail leaves one behind; remove those by hand:
#
#     docker rm -f $(docker ps -aq --filter "name=tofu-db-test")
#
# ⚠ --volumes also deletes the Transit key the tofu state is encrypted with, so
#   no state could be read again. It first asks the running tofu runner whether
#   any state still tracks a resource, and refuses if one does (reclaim it with
#   --cleanup) or if it cannot tell (runner down, OpenBao sealed). When nothing
#   is tracked, the state files go with the storage, since they would be
#   unreadable anyway. FORCE_WIPE=1 wipes regardless and keeps those states.
#
# Usage:
#   ./scripts/down.sh              # stop the containers
#   ./scripts/down.sh --volumes    # containers + OpenBao storage (credentials are lost)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

YELLOW='\033[1;33m'; GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

WIPE=0
for arg in "$@"; do
	case "$arg" in
	--volumes) WIPE=1 ;;
	-h|--help) awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]:-$0}"; exit 0 ;;
	*) echo "unknown option: $arg" >&2; exit 1 ;;
	esac
done

# tofu_state_files — every state file and backup under tofu/, one per line.
tofu_state_files() {
	find "$ROOT_DIR/tofu" -type f \( -name terraform.tfstate -o -name terraform.tfstate.backup \) \
		-not -path '*/.terraform/*' 2>/dev/null
}

# Before --volumes: does any state still track a resource? Checked while the
# runner is still up, since only it can decrypt the states. The versions
# modules hold data sources only and are skipped.
#   The runner prints one line per state: "<status> <path relative to /work>",
#   status being busy (tracks a resource), empty, or unknown (unreadable).
DROP_STATES=0
if [ "$WIPE" = "1" ] && [ -n "$(tofu_state_files)" ] && [ "${FORCE_WIPE:-}" != "1" ]; then
	if ! docker ps --format '{{.Names}}' | grep -qx cptfm-tofu-runner; then
		echo -e "${RED}Refusing --volumes:${NC} tofu state files exist, and with the tofu runner down" >&2
		echo "  there is no telling whether they still track resources at the CSP." >&2
		echo "  Start the stack (./scripts/up.sh) and run this again, or FORCE_WIPE=1 to wipe anyway." >&2
		exit 1
	fi
	CHECK="$(docker exec cptfm-tofu-runner bash -c '
		set -uo pipefail
		set -a; . /work/.env; set +a
		export VAULT_ADDR=http://openbao:8200 BAO_TOKEN="${VAULT_TOKEN:-${BAO_TOKEN:-}}"
		for f in /work/tofu/*/terraform.tfstate /work/tofu/*/*/terraform.tfstate \
		         /work/tofu/*/terraform.tfstate.d/*/terraform.tfstate \
		         /work/tofu/*/*/terraform.tfstate.d/*/terraform.tfstate; do
			[ -f "$f" ] || continue
			case "$f" in */versions/*) continue ;; esac
			case "$f" in
				*/terraform.tfstate.d/*) mod="${f%/terraform.tfstate.d/*}"; ws="${f%/terraform.tfstate}"; ws="${ws##*/}" ;;
				*)                       mod="${f%/terraform.tfstate}";   ws="default" ;;
			esac
			if ! out="$(cd "$mod" && TF_WORKSPACE="$ws" tofu state list 2>/dev/null)"; then
				echo "unknown ${f#/work/}"
			elif printf "%s\n" "$out" | grep -qvE "^data\.|^$"; then
				echo "busy ${f#/work/}"
			else
				echo "empty ${f#/work/}"
			fi
		done
	' 2>&1)" || CHECK="unknown (docker exec failed: ${CHECK:-no output})"
	# Anything but "empty" blocks, including a line the loop did not print.
	BLOCKED="$(printf '%s\n' "$CHECK" | awk 'NF && $1 != "empty" { print "    " $0 }')"
	if [ -n "$BLOCKED" ]; then
		echo -e "${RED}Refusing --volumes:${NC} it deletes the Transit key these tofu states are encrypted with." >&2
		echo "$BLOCKED" >&2
		echo "  busy    — still tracks a resource: ./scripts/aws-db-matrix.sh --cleanup (or ncp-)" >&2
		echo "  unknown — could not be read (OpenBao sealed? ./scripts/up.sh)" >&2
		echo "  Or run with FORCE_WIPE=1 to wipe anyway (those states can never be read again)." >&2
		exit 1
	fi
	DROP_STATES=1
fi

docker compose down

if [ "$WIPE" = "1" ]; then
	echo -e "${YELLOW}--volumes — removing OpenBao's storage and unseal key.${NC}"
	echo "  The stored CSP keys and DB passwords go with them, so the next ./scripts/up.sh needs them again."
	rm -rf "$ROOT_DIR/container-volume/openbao-data" \
	       "$ROOT_DIR/init/openbao/secrets/openbao-init.json"
	# The states are encrypted under the key just removed. Every one tracks
	# nothing (checked above), so they go too; under FORCE_WIPE only the
	# versions caches do, and the rest stay for the record.
	tofu_state_files | while read -r f; do
		case "$f" in
			*/versions/*) ;;
			*) [ "$DROP_STATES" = "1" ] || continue ;;
		esac
		rm -f "$f"
	done
	echo -e "${GREEN}Removed.${NC}"
fi
