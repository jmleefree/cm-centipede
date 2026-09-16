#!/usr/bin/env bash
# ==============================================================================
# status.sh — what exists right now
# ------------------------------------------------------------------------------
#   ./scripts/status.sh          every CSP in BEETLEENV_CSPS
#   ./scripts/status.sh aws      one CSP
#
#   READ-ONLY. Deletes nothing, creates nothing, and does not touch the
#   namespace. Deleting is deprovision.sh's job and only its job.
#
#   Everything here costs money while it runs, so "what is still up" is the
#   question worth being able to ask cheaply at the end of a day.
#
# A SUMMARY, NOT A DETAIL VIEW
#   Every CSP at once, one line per resource: its id, and whether it is running.
#   Nothing about how to reach it - no endpoint, no IP, no CSP resource id, and
#   no per-node rows. That is conn-info.sh's job, for one CSP at a time, and
#   keeping the split visible in the output is what stops the two from becoming
#   the same command printed twice.
#
#   The labels are the cm-beetle API parameter names, the same ones conn-info.sh
#   uses, so a resource is recognisable across both.
#
#   The list calls are made once and filtered per CSP, rather than once per CSP:
#   cm-beetle paces its calls to cb-tumblebug, and one namespace holds every
#   CSP's resources anyway.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/beetle.sh
. "${SCRIPT_DIR}/lib/beetle.sh"
# shellcheck source=./lib/namespace.sh
. "${SCRIPT_DIR}/lib/namespace.sh"

usage() {
    cat <<'EOF'
Usage: ./scripts/status.sh [csp]

  (no argument)  every CSP in BEETLEENV_CSPS
  <csp>          just that one

Read-only. To delete anything, use ./scripts/deprovision.sh
EOF
}

CSP_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -*)        usage >&2; die "unknown option: $1" ;;
        *)
            if [ -z "$CSP_ARG" ]; then CSP_ARG="$1"
            else usage >&2; die "unexpected argument: $1"
            fi
            ;;
    esac
    shift
done

preflight

if [ -n "$CSP_ARG" ]; then
    validate_csp "$CSP_ARG"
    CSPS="$(csp_lower "$CSP_ARG")"
else
    CSPS="${BEETLEENV_CSPS:-}"
fi

NS_PATH="$(urlq "$BEETLEENV_NS")"

printf '\n'
log_step "nsId ${BEETLEENV_NS}"

if [ -n "${TUMBLEBUG_URL:-}" ] && ! ns_exists; then
    printf '  the namespace does not exist - ./scripts/up.sh creates it\n\n'
    exit 0
fi

if [ -z "$CSPS" ]; then
    printf '  BEETLEENV_CSPS is empty, so there is nothing to report on\n\n'
    exit 0
fi

# ------------------------------------------------------------------------------
# One pass over the namespace
# ------------------------------------------------------------------------------

fetch() {
    if bt_get "$1"; then bt_payload; else printf '{}'; fi
}

RDBMS_ALL="$(fetch "/migration/middleware/ns/${NS_PATH}/rdbms")"
BUCKETS_ALL="$(fetch "/migration/middleware/ns/${NS_PATH}/objectStorage")"
INFRA_ALL="$(fetch "/migration/ns/${NS_PATH}/infra")"
VNETS_ALL="$(fetch "/migration/ns/${NS_PATH}/resources/vNet")"

# rows <json> <jq path> <prefix> <line format> — the names of ours, one per line.
rows() {
    printf '%s' "$1" | jq -r --arg p "$3" \
        "${2}? | select((.id // .name) | startswith(\$p)) | ${4}" 2>/dev/null || true
}

# section <label> <rows> — print, or say there are none.
#
#   The labels are the cm-beetle API parameter names, the same as conn-info.sh
#   uses: what stands beside "infraId" is what an infraId path segment takes.
section() {
    printf '    %-11s' "$1"
    if [ -z "$2" ]; then
        printf -- '-\n'
    else
        printf '%s\n' "$2" | sed '2,$s/^/               /'
    fi
}

TOTAL=0

for CSP in $CSPS; do
    validate_csp "$CSP"
    CSP="$(csp_lower "$CSP")"
    P="$(name_prefix_of "$CSP")"

    # Engine and node count stay: they say which resource this is and how much of
    # it there is. Endpoints, IPs and CSP ids do not - those are conn-info.sh's.
    R="$(rows "$RDBMS_ALL"   '.rdbms[]'         "$P" '"\(.id // .name)  [\(.dbEngine // "?") \(.status // "?")]"')"
    B="$(rows "$BUCKETS_ALL" '.objectStorage[]' "$P" '"\(.id // .name)  [\(.status // "?")]"')"
    I="$(rows "$INFRA_ALL"   '.infra[]'         "$P" '([.node[]?] | length) as $n |
        "\(.id // .name)  [\(.status // "?"), \($n) node\(if $n == 1 then "" else "s" end)]"')"
    V="$(rows "$VNETS_ALL"   '.vNet[]'          "$P" '"\(.id // .name)  [\(.status // "?")]"')"

    printf '\n'
    # nsId is not repeated here: it is the same for every CSP and stands in the
    # header above.
    log_step "${CSP} — connection $(connection_name "$CSP")"
    section "rdbmsId" "$R"
    section "osId" "$B"
    section "infraId" "$I"
    section "vNetId" "$V"

    for block in "$R" "$B" "$I" "$V"; do
        if [ -n "$block" ]; then
            TOTAL=$((TOTAL + $(printf '%s\n' "$block" | grep -c '')))
        fi
    done
done

printf '\n'
if [ "$TOTAL" -eq 0 ]; then
    printf '  nothing of ours is running.\n'
    printf '  ./scripts/provision.sh <csp> database   creates some\n\n'
else
    printf '  %s resource(s) named %s-<csp>-* are up.\n' "$TOTAL" "$BEETLEENV_NAME_PREFIX"
    printf '  ./scripts/conn-info.sh <csp>            how to reach them\n'
    printf '  ./scripts/deprovision.sh <csp> all      delete them (the namespace stays)\n\n'
fi
