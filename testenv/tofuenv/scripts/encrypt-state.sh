#!/usr/bin/env bash
# ==============================================================================
# encrypt-state.sh — encrypt the tofu state, and drop the CSP keys it still holds
# ------------------------------------------------------------------------------
#   ./scripts/encrypt-state.sh           # encrypt, drop the old data sources and
#                                        #   the plaintext backups
#   ./scripts/encrypt-state.sh --check   # only list them; exit 1 if any is left
#
#   Why:
#     tofu-runner encrypts every state it writes (TF_ENCRYPTION in
#     docker-compose.yaml) and refuses to read a plaintext one, so a state written
#     before encryption was turned on stops every tofu command on its module with
#     "encountered unencrypted payload without unencrypted method configured".
#     A state keeps all that its data sources read and its resources hold - DB
#     passwords, SSH private keys - so a plaintext one is a secret left on disk.
#
#   How it works:
#     Inside tofu-runner, every terraform.tfstate under tofu/ (the workspaces in
#     terraform.tfstate.d/<prefix>/, and the module root, which is the default
#     workspace the versions modules use) is checked for the encrypted format.
#     A plaintext one is read with a fallback to the unencrypted method and
#     written straight back (tofu state pull | tofu state push -), which
#     encrypts it. The serial is raised by one on the way: pull re-serializes
#     the state, and push refuses a state that differs from the one on disk
#     under the same serial (the lineage check stays, unlike push -force).
#     The plaintext never touches the disk on the way.
#
#     The modules used to read the CSP keys with a data.vault_kv_secret_v2.<csp>
#     and now get them from scripts/lib/csp-env.sh. A state written before still
#     tracks that data source - with the keys in it - and tofu can no longer
#     plan it, since the module has no vault provider to read its schema with
#     ("unavailable provider registry.opentofu.org/hashicorp/vault"). It is
#     removed with tofu state rm. The DB and VM password data sources (db, vm)
#     stay: the modules still read those.
#
#     Last, a plaintext terraform.tfstate.backup next to a state that is now
#     encrypted is removed: it is the version before the last write, which
#     nothing reads. Nothing is planned or applied and no CSP API is called.
#
#   Notes:
#     - Needs OpenBao unsealed and tofu-runner started by ./scripts/up.sh, which
#       creates the Transit key (init/openbao/openbao-transit.sh).
#     - Safe to run again: encrypted states are left as they are.
#     - ./scripts/up.sh runs --check and points here when something is left.
# ==============================================================================
set -euo pipefail

RUNNER="tofuenv-runner"
GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'; NC='\033[0m'

MODE="encrypt"
case "${1:-}" in
    "") ;;
    --check) MODE="check" ;;
    -h|--help) sed -n '3,6p' "$0" | sed 's/^#  //'; exit 0 ;;
    *) echo -e "${RED}unknown argument: $1${NC}" >&2; echo "Usage: $0 [--check]" >&2; exit 1 ;;
esac

if ! docker ps --format '{{.Names}}' | grep -q "^${RUNNER}$"; then
    echo -e "${RED}The ${RUNNER} container is not running. Run ./scripts/up.sh first.${NC}" >&2; exit 1
fi

[ "$MODE" = "encrypt" ] && echo -e "${CYAN}=== encrypting plaintext tofu state ===${NC}"

# The runner prints one line per file: "<status> <path relative to /work>".
#   encrypted | plaintext | converted | failed | stale | stale-removed |
#   backup-removed | backup-kept | unreadable
OUT="$(docker exec -e MODE="$MODE" "$RUNNER" bash -c '
    set -uo pipefail
    if [ -z "${TF_ENCRYPTION:-}" ]; then
        echo "error TF_ENCRYPTION is not set in the runner: recreate it with ./scripts/up.sh"
        exit 0
    fi
    # The runner config with the unencrypted method added and "enforced = true"
    # swapped for a fallback to it, so that a plaintext state can be read. Only
    # the commands run here get it: the runner does not declare the method, as
    # tofu warns on every command while it is declared.
    fb="fallback { method = method.unencrypted.migrate }"
    um="method \"unencrypted\" \"migrate\" {}"
    MIGRATE="${TF_ENCRYPTION//enforced = true/$fb}"
    case "$MIGRATE" in
        *"$fb"*) ;;
        *) echo "error TF_ENCRYPTION has no \"enforced = true\" to swap: check docker-compose.yaml"; exit 0 ;;
    esac
    case "$MIGRATE" in
        *"$um"*) ;;
        *) MIGRATE="$MIGRATE
$um" ;;
    esac

    # is_encrypted <file> — 0 encrypted, 1 plaintext, 2 not a state file
    is_encrypted() {
        local r
        r="$(jq -r "if type == \"object\" then has(\"encrypted_data\") else \"bad\" end" "$1" 2>/dev/null)" || return 2
        case "$r" in true) return 0 ;; false) return 1 ;; *) return 2 ;; esac
    }

    # locate <state file> — set mod (module dir) and ws (its workspace)
    locate() {
        case "$1" in
            */terraform.tfstate.d/*) mod="${1%/terraform.tfstate.d/*}"; ws="${1%/terraform.tfstate}"; ws="${ws##*/}" ;;
            *)                       mod="${1%/terraform.tfstate}";   ws="default" ;;
        esac
    }
    STATES="/work/tofu/*/*/terraform.tfstate /work/tofu/*/*/terraform.tfstate.d/*/terraform.tfstate"

    for f in $STATES; do
        [ -f "$f" ] || continue
        rel="${f#/work/}"
        is_encrypted "$f"; rc=$?
        case "$rc" in
            0) echo "encrypted $rel"; continue ;;
            2) echo "unreadable $rel"; continue ;;
        esac
        if [ "$MODE" = "check" ]; then
            echo "plaintext $rel"; continue
        fi
        locate "$f"
        if ( cd "$mod" \
             && { [ -d .terraform ] || flock /work/.tofu-plugin-cache/.init.lock tofu init -input=false >/dev/null; } \
             && TF_WORKSPACE="$ws" TF_ENCRYPTION="$MIGRATE" tofu state pull \
              | jq ".serial += 1" \
              | TF_WORKSPACE="$ws" TF_ENCRYPTION="$MIGRATE" tofu state push - ) >/dev/null 2>&1 \
           && is_encrypted "$f"; then
            echo "converted $rel"
        else
            echo "failed $rel"
        fi
    done

    # The CSP credential data sources the modules no longer have (see the header).
    for f in $STATES; do
        [ -f "$f" ] && is_encrypted "$f" || continue
        rel="${f#/work/}"
        locate "$f"
        stale="$(cd "$mod" && TF_WORKSPACE="$ws" tofu state list 2>/dev/null \
                 | grep -E "^data\.vault_kv_secret_v2\.(aws|ncp|alibaba|azure|gcp)$" || true)"
        [ -n "$stale" ] || continue
        if [ "$MODE" = "check" ]; then
            echo "stale $rel"; continue
        fi
        # shellcheck disable=SC2086 # one address per word
        if ( cd "$mod" && TF_WORKSPACE="$ws" tofu state rm $stale ) >/dev/null 2>&1; then
            echo "stale-removed $rel"
        else
            echo "failed $rel"
        fi
    done

    for b in /work/tofu/*/*/terraform.tfstate.backup /work/tofu/*/*/terraform.tfstate.d/*/terraform.tfstate.backup; do
        [ -f "$b" ] || continue
        rel="${b#/work/}"
        is_encrypted "$b" && { echo "encrypted $rel"; continue; }
        if [ "$MODE" = "check" ]; then
            echo "plaintext $rel"; continue
        fi
        s="${b%.backup}"
        if [ -f "$s" ] && is_encrypted "$s"; then
            rm -f "$b" && echo "backup-removed $rel"
        else
            echo "backup-kept $rel"
        fi
    done
')"

LEFT=0; FAILED=0; DONE=0; OK=0
while read -r status path; do
    case "$status" in
        encrypted)      OK=$((OK + 1)); [ "$MODE" = "check" ] && echo -e "  ${GREEN}encrypted${NC}  $path" ;;
        plaintext)      LEFT=$((LEFT + 1));     echo -e "  ${YELLOW}plaintext${NC}  $path" ;;
        converted)      DONE=$((DONE + 1));     echo -e "  ${GREEN}encrypted${NC}  $path" ;;
        stale)          LEFT=$((LEFT + 1));     echo -e "  ${YELLOW}csp keys${NC}   $path (still tracks the old CSP credential data source)" ;;
        stale-removed)  DONE=$((DONE + 1));     echo -e "  ${GREEN}cleaned${NC}    $path (CSP credential data source removed)" ;;
        backup-removed) DONE=$((DONE + 1));     echo -e "  ${GREEN}removed${NC}    $path (plaintext backup)" ;;
        backup-kept)    LEFT=$((LEFT + 1));     echo -e "  ${YELLOW}kept${NC}       $path (plaintext backup; its state is not encrypted)" ;;
        failed)         FAILED=$((FAILED + 1)); echo -e "  ${RED}failed${NC}     $path" ;;
        unreadable)     FAILED=$((FAILED + 1)); echo -e "  ${RED}unreadable${NC} $path (not a state file)" ;;
        error)          FAILED=$((FAILED + 1)); echo -e "${RED}${path}${NC}" ;;
    esac
done <<<"$OUT"

if [ "$MODE" = "check" ]; then
    if [ "$LEFT" -gt 0 ] || [ "$FAILED" -gt 0 ]; then
        echo -e "${YELLOW}${LEFT} file(s) left to fix. Fix them: ./scripts/encrypt-state.sh${NC}"
        exit 1
    fi
    echo -e "${GREEN}All ${OK} state file(s) are encrypted.${NC}"
    exit 0
fi

if [ "$FAILED" -gt 0 ]; then
    echo -e "${RED}=== ${FAILED} file(s) could not be encrypted ===${NC}" >&2
    echo "  Run the same by hand to see why (OpenBao sealed? the Transit key missing?):" >&2
    echo "    docker exec -e TF_WORKSPACE=<prefix> ${RUNNER} bash -c 'cd /work/tofu/<csp>/<module> && tofu state list'" >&2
    exit 1
fi
if [ "$DONE" -eq 0 ] && [ "$LEFT" -eq 0 ]; then
    echo -e "${GREEN}Nothing to do: all ${OK} state file(s) are already encrypted.${NC}"
else
    echo -e "${GREEN}=== done: ${DONE} file(s) encrypted or removed, ${OK} already encrypted ===${NC}"
fi
[ "$LEFT" -eq 0 ] || exit 1
