#!/usr/bin/env bash
# ==============================================================================
# provision.sh — create resources (tofu init + validate + apply)
# ------------------------------------------------------------------------------
#   ./scripts/provision.sh <csp> <resource>
#     aws : bucket | vm | database
#     ncp : bucket | vm | database
#
#   Examples:
#     ./scripts/provision.sh aws bucket
#     ./scripts/provision.sh aws database
#     ./scripts/provision.sh ncp database
#
#   How it works:
#     Runs init -> validate -> apply for /work/tofu/<csp>/<resource> inside the
#     tofuenv-runner container and prints the outputs (connection info) afterwards.
#     Credentials and settings come from /work/.env inside the container, with
#     VAULT_ADDR overridden to the compose network address (http://openbao:8200).
#
#   Repeated runs:
#     A resource that already holds state is reported and skipped, so running the same
#     command twice costs nothing and creates nothing. Pass --force to apply anyway -
#     needed to converge a module whose previous apply stopped halfway, and to pick up
#     changed .env values.
#
#   NCP notes:
#     - NCP has no default VPC, so tofu/ncp/vm and tofu/ncp/database resolve the
#       VPC/subnet/ACG by name from tofu/ncp/network. That module is handled
#       automatically here and is not a resource you pass on the command line:
#       it is applied first whenever vm or database needs it and is still missing.
#       deprovision.sh destroys it once no module needs it any more.
#     - Changing TF_VAR_ncp_name_prefix after tofu/ncp/network exists breaks that
#       by-name lookup. It is detected here and reported with the way out, rather
#       than left to fail as a bare "Invalid index" inside tofu.
#     - Managed databases take roughly 30 minutes to create.
#     - The tofu/ncp/versions module only holds data sources for looking up engine
#       versions, images and specs. Use ./scripts/ncp-db-versions.sh for that.
# ==============================================================================
set -euo pipefail

RUNNER="tofuenv-runner"
GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'

usage() {
    cat >&2 <<'EOF'
Usage: provision.sh <csp> <resource> [--force]
  aws : bucket | vm | database
  ncp : bucket | vm | database

  A resource that already holds state is reported and left alone; --force re-applies
  it, which is what converges a module whose previous apply stopped halfway.

  ncp/network is created automatically when vm or database needs it.
  For AWS engine versions, instance classes and the AMI: ./scripts/aws-db-versions.sh
  For NCP engine versions, images and specs: ./scripts/ncp-db-versions.sh
EOF
    exit 1
}

CSP=""; RESOURCE=""; FORCE=0
for arg in "$@"; do
    case "$arg" in
        -f|--force) FORCE=1 ;;
        -h|--help)  usage ;;
        *)
            if [ -z "$CSP" ]; then
                CSP="$arg"
            elif [ -z "$RESOURCE" ]; then
                RESOURCE="$arg"
            else
                echo "unexpected argument: $arg" >&2; usage
            fi
            ;;
    esac
done
[ -z "$CSP" ] || [ -z "$RESOURCE" ] && usage

case "$CSP" in
    aws|ncp) ;;
    *) echo "invalid csp: $CSP (supported: aws, ncp)" >&2; usage ;;
esac

case "$RESOURCE" in
    bucket|vm|database) ;;
    *) echo "invalid resource for ${CSP}: $RESOURCE" >&2; usage ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODULE="tofu/${CSP}/${RESOURCE}"

if [ ! -d "$ROOT_DIR/$MODULE" ]; then
    echo -e "${RED}module not found: $MODULE${NC}" >&2; exit 1
fi
if ! docker ps --format '{{.Names}}' | grep -q "^${RUNNER}$"; then
    echo -e "${RED}The ${RUNNER} container is not running. Run ./scripts/up.sh first.${NC}" >&2; exit 1
fi

# has_managed_state <module> — true when the module tracks a real resource. Data sources
#   are filtered out, and outputs are ignored: a module whose resources were removed from
#   state can keep stale outputs, which would otherwise read as "already provisioned".
has_managed_state() {
    local mod="$1" out
    out="$(docker exec "$RUNNER" bash -c '
        cd "/work/'"$mod"'" 2>/dev/null || exit 0
        tofu state list 2>/dev/null || true
    ' | grep -v '^data\.' || true)"
    [ -n "$(printf %s "$out" | tr -d '[:space:]')" ]
}

# ncp_name_prefix — the prefix the NCP modules will actually use: TF_VAR_ncp_name_prefix
#   from .env, or the module default when .env does not set it.
ncp_name_prefix() {
    local p
    p="$(docker exec "$RUNNER" bash -c '
        set -a; . /work/.env 2>/dev/null; set +a
        printf %s "${TF_VAR_ncp_name_prefix:-}"
    ')"
    if [ -z "$p" ]; then
        p="$(sed -n '/variable "ncp_name_prefix"/,/^}/s/.*default *= *"\([^"]*\)".*/\1/p' \
             "$ROOT_DIR/tofu/ncp/vm/variables.tf" | head -1)"
    fi
    printf %s "$p"
}

# ncp_network_vpc_name — the vpc_name output of tofu/ncp/network; empty when it holds
#   no state.
#   The result is shape-checked, because `tofu output -raw` prints a multi-line
#   "No outputs found" warning on STDOUT and still exits 0 when the module has none.
#   A VPC name is a single token of letters, digits and hyphens, so anything else is
#   that warning and has to be read as "no network".
ncp_network_vpc_name() {
    local name
    name="$(docker exec "$RUNNER" bash -c '
        cd /work/tofu/ncp/network 2>/dev/null || exit 0
        tofu output -raw vpc_name 2>/dev/null || true
    ' | tr -d '[:space:]')"
    case "$name" in
        ''|*[!a-zA-Z0-9-]*) printf '' ;;
        *)                  printf %s "$name" ;;
    esac
}

# ncp_prefix_mismatch — true when tofu/ncp/network exists but was created under a
#   different prefix than the one in effect now.
#   This has to be caught up front. ncp/vm and ncp/database resolve the VPC, subnet and
#   ACG BY NAME, so a changed prefix makes every lookup return an empty list and tofu
#   fails with a bare "Invalid index ... vpcs is empty list of object" that says nothing
#   about the real cause.
NCP_PREFIX=""; NCP_NETWORK_VPC=""
ncp_prefix_mismatch() {
    NCP_PREFIX="$(ncp_name_prefix)"
    NCP_NETWORK_VPC="$(ncp_network_vpc_name)"
    [ -n "$NCP_NETWORK_VPC" ] && [ "$NCP_NETWORK_VPC" != "${NCP_PREFIX}-vpc" ]
}

# apply_module <module> [show_outputs] — init + validate + apply inside the runner
apply_module() {
    local mod="$1" show="${2:-yes}"
    docker exec "$RUNNER" bash -c '
        set -euo pipefail
        set -a; . /work/.env; set +a
        export VAULT_ADDR=http://openbao:8200
        mkdir -p /work/.tofu-plugin-cache /work/ssh_keys
        cd "/work/'"$mod"'"
        tofu init -input=false
        tofu validate
        tofu apply -auto-approve
        if [ "'"$show"'" = "yes" ]; then
            echo
            echo "=================== OUTPUTS (connection info) ==================="
            tofu output
        fi
    '
}

# Already provisioned? Report it and stop, so a repeated command is a no-op instead of
# a fresh apply. Tracking a resource is the signal; it does not prove the module applied
# cleanly to the end, which is why --force exists to re-apply and converge one that
# stopped halfway.
if [ "$FORCE" -eq 0 ] && has_managed_state "$MODULE"; then
    echo -e "${YELLOW}=== ${CSP}/${RESOURCE} is already provisioned - nothing to do ===${NC}"
    docker exec "$RUNNER" bash -c '
        cd "/work/'"$MODULE"'"
        tofu output 2>/dev/null || true
    ' | sed 's/^/  /'
    echo
    echo "  Connection info  :  ./scripts/conn-info.sh ${CSP} ${RESOURCE}"
    echo "  Re-apply anyway  :  ./scripts/provision.sh ${CSP} ${RESOURCE} --force"
    echo "  Destroy          :  ./scripts/deprovision.sh ${CSP} ${RESOURCE}"
    exit 0
fi

# NCP vm/database resolve the VPC, subnet and ACG by name from tofu/ncp/network,
# so it has to exist first. It is applied here rather than exposed as a command.
if [ "$CSP" = "ncp" ] && { [ "$RESOURCE" = "vm" ] || [ "$RESOURCE" = "database" ]; }; then
    if ncp_prefix_mismatch; then
        echo -e "${RED}=== TF_VAR_ncp_name_prefix does not match the existing ncp/network ===${NC}" >&2
        echo "  ncp/network was created as : ${NCP_NETWORK_VPC}" >&2
        echo "  ${CSP}/${RESOURCE} will look for : ${NCP_PREFIX}-vpc" >&2
        echo >&2
        echo "  ncp/vm and ncp/database resolve the VPC, subnet and ACG BY NAME, so the" >&2
        echo "  lookup finds nothing and the apply fails on an empty list." >&2
        echo >&2
        echo "  Re-create the network under the new prefix (it holds no data):" >&2
        echo "    ./scripts/deprovision.sh ncp ${RESOURCE}" >&2
        echo "    ./scripts/provision.sh ncp ${RESOURCE}" >&2
        echo >&2
        echo "  Or keep what exists by putting TF_VAR_ncp_name_prefix back to" >&2
        echo "  '${NCP_NETWORK_VPC%-vpc}' in .env." >&2
        exit 1
    fi
    if ! has_managed_state "tofu/ncp/network"; then
        echo -e "${YELLOW}=== prerequisite: creating ncp/network (VPC + PUBLIC subnet + ACG) ===${NC}"
        apply_module "tofu/ncp/network" no
        echo -e "${GREEN}ncp/network ready.${NC}"
        echo
    fi
fi

echo -e "${CYAN}=== provision: ${CSP}/${RESOURCE} ===${NC}"
if [ "$CSP" = "ncp" ] && [ "$RESOURCE" = "database" ]; then
    echo -e "${YELLOW}Managed DB creation takes ~30 minutes. Do not interrupt this command.${NC}"
fi

apply_module "$MODULE"
echo -e "${GREEN}=== done: ${CSP}/${RESOURCE} ===${NC}"
echo "  Reveal a sensitive output (password, connection_uri, ...):"
echo "    docker exec ${RUNNER} bash -c 'cd /work/${MODULE} && tofu output -raw <output_name>'"

if [ "$CSP" = "ncp" ] && [ "$RESOURCE" = "database" ]; then
    echo
    echo -e "${YELLOW}Next step — managed DBs are not reachable from outside yet.${NC}"
    echo "  A public domain must be issued once per DB server in the NCP console:"
    echo "    Database > Cloud DB for <engine> > select the DB server > DB Management > Public domain"
    echo "  Then reflect and verify it with:  ./scripts/ncp-db-domain.sh"
fi
