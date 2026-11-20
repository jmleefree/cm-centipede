#!/usr/bin/env bash
# ==============================================================================
# prepare.sh — create resources (tofu init + validate + apply)
# ------------------------------------------------------------------------------
#   ./scripts/prepare.sh <csp> <resource> [--engine e1,e2] [--force]
#     aws     : bucket | vm | database
#     ncp     : bucket | vm | database
#     alibaba : bucket | vm | database
#     azure   : bucket | vm | database
#
#   Examples:
#     ./scripts/prepare.sh aws bucket
#     ./scripts/prepare.sh aws database
#     ./scripts/prepare.sh aws database --engine postgresql
#     ./scripts/prepare.sh ncp database --engine mysql,mongodb
#
#   One engine at a time (database only):
#     --engine adds the engines named to the ones the prefix already runs; those keep
#     running. aws: mysql | mariadb | postgresql, ncp: mysql | postgresql | mongodb,
#     alibaba: mysql | mariadb | postgresql | mongodb, azure: mysql | postgresql | mongodb.
#     Without --engine a fresh database module gets every engine, as before. The
#     list is worked out here and handed to tofu as TF_VAR_<csp>_db_engines (see
#     scripts/lib/db-engines.sh); it is not a .env setting.
#
#   How it works:
#     Runs init -> validate -> apply for /work/tofu/<csp>/<resource> inside the
#     tofuenv-runner container and prints the outputs (connection info) afterwards.
#     Credentials and settings come from /work/.env inside the container, with
#     VAULT_ADDR overridden to the compose network address (http://openbao:8200).
#
#   One environment per prefix:
#     Every module keeps one state per TF_VAR_<csp>_name_prefix (a tofu workspace,
#     see scripts/lib/workspace.sh), and this script only ever applies the prefix
#     .env sets. Changing the prefix starts a new environment next to the old one;
#     the old one is not touched and keeps costing money - ./scripts/list.sh shows
#     what is still prepared. The bucket name is not derived from the prefix,
#     so it is checked against every other prefix's bucket before the apply.
#
#   Repeated runs:
#     A resource that already holds state is reported and skipped, so running the same
#     command twice costs nothing and creates nothing. Pass --force to apply anyway -
#     needed to converge a module whose previous apply stopped halfway, and to pick up
#     changed .env values. With --engine, the check is per engine: the run is skipped
#     only when every engine named is already there. --force on a database module
#     without --engine re-applies the engines it already runs, so one removed with
#     teardown.sh --engine does not come back.
#
#   NCP notes:
#     - NCP has no default VPC, so tofu/ncp/vm and tofu/ncp/database resolve the
#       VPC/subnet/ACG by name from tofu/ncp/network. That module is handled
#       automatically here and is not a resource you pass on the command line:
#       it is applied first whenever vm or database needs it and the prefix has
#       none yet. teardown.sh destroys it once no module of the prefix needs it.
#     - Managed databases take roughly 30 minutes to create.
#     - The tofu/ncp/versions module only holds data sources for looking up engine
#       versions, images and specs. Use ./scripts/ncp-db-versions.sh for that.
#
#   Alibaba notes:
#     - tofu/alibaba/network (VPC + vSwitch + security group) is handled the same
#       way as ncp/network: applied first whenever vm or database needs it.
#     - The public endpoints of RDS and MongoDB are created by the database
#       module itself; nothing has to be done in the console.
#     - The tofu/alibaba/versions module only holds data sources for looking up
#       zones, RDS versions and classes, and ECS types. Use
#       ./scripts/alibaba-db-versions.sh for that.
#     - RDS PostgreSQL needs the service-linked role AliyunServiceRoleForRdsPgsqlOnEcs
#       (lets RDS attach network interfaces; free, once per account), or the create
#       fails with ServiceLinkedRole.NotExist. When postgresql is to be created, it
#       is checked here and created if missing, through the aliyun CLI in the
#       runner. It is account-wide, so no module owns it and teardown leaves it.
#       The RAM user needs ram:CreateServiceLinkedRole for that one call.
#
#   Azure notes:
#     - There is no network module: tofu/azure/vm builds its own VNet, subnet and
#       NSG in its resource group (<prefix>-vm-rg), and the databases are reached
#       over their public endpoints. vm and database each own a resource group,
#       which teardown.sh deletes with everything in it.
#     - tofu/azure/bucket creates only the container, in the existing storage
#       account given as AZURE_S3_ACCESS_KEY; the account is not created here.
#     - azurerm 5.x registers no resource provider by default. Each module
#       registers the ones it uses (Microsoft.Storage, .Compute, .Network, ...),
#       so the service principal must be allowed to - Contributor is.
# ==============================================================================
set -euo pipefail

RUNNER="tofuenv-runner"
GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'

usage() {
    cat >&2 <<'EOF'
Usage: prepare.sh <csp> <resource> [--engine e1,e2] [--force]
  aws     : bucket | vm | database
  ncp     : bucket | vm | database
  alibaba : bucket | vm | database
  azure   : bucket | vm | database

  A resource that already holds state is reported and left alone; --force re-applies
  it, which is what converges a module whose previous apply stopped halfway.

  --engine (database only) adds just the engines named; the ones already running stay.
    aws     : mysql | mariadb | postgresql
    ncp     : mysql | postgresql | mongodb
    alibaba : mysql | mariadb | postgresql | mongodb
    azure   : mysql | postgresql | mongodb

  ncp/network and alibaba/network are created automatically when vm or database needs it.
  azure has no network module: the vm module builds its own network.
  For AWS engine versions, instance classes and the AMI: ./scripts/aws-db-versions.sh
  For NCP engine versions, images and specs: ./scripts/ncp-db-versions.sh
  For Alibaba zones, RDS versions and classes, ECS types: ./scripts/alibaba-db-versions.sh
  For Azure DB versions and SKUs, VM sizes and images: ./scripts/azure-db-versions.sh
EOF
    exit 1
}

CSP=""; RESOURCE=""; FORCE=0; ENGINE_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        -f|--force) FORCE=1 ;;
        -h|--help)  usage ;;
        --engine)
            [ $# -ge 2 ] || { echo "--engine needs a value" >&2; usage; }
            ENGINE_ARG="$2"; shift ;;
        --engine=*) ENGINE_ARG="${1#--engine=}" ;;
        *)
            if [ -z "$CSP" ]; then
                CSP="$1"
            elif [ -z "$RESOURCE" ]; then
                RESOURCE="$1"
            else
                echo "unexpected argument: $1" >&2; usage
            fi
            ;;
    esac
    shift
done
[ -z "$CSP" ] || [ -z "$RESOURCE" ] && usage

case "$CSP" in
    aws|ncp|alibaba|azure) ;;
    *) echo "invalid csp: $CSP (supported: aws, ncp, alibaba, azure)" >&2; usage ;;
esac

case "$RESOURCE" in
    bucket|vm|database) ;;
    *) echo "invalid resource for ${CSP}: $RESOURCE" >&2; usage ;;
esac

if [ -n "$ENGINE_ARG" ] && [ "$RESOURCE" != "database" ]; then
    echo "--engine only applies to database" >&2; usage
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODULE="tofu/${CSP}/${RESOURCE}"

if [ ! -d "$ROOT_DIR/$MODULE" ]; then
    echo -e "${RED}module not found: $MODULE${NC}" >&2; exit 1
fi
if ! docker ps --format '{{.Names}}' | grep -q "^${RUNNER}$"; then
    echo -e "${RED}The ${RUNNER} container is not running. Run ./scripts/up.sh first.${NC}" >&2; exit 1
fi

# shellcheck source=./lib/workspace.sh
. "$SCRIPT_DIR/lib/workspace.sh"
ws_load "$CSP"

# Before any apply. The CSP keys are read from OpenBao, but the bucket names are
# read from .env inside the runner, and a ChangeMe there would name a bucket.
# shellcheck source=./lib/env-perm.sh
. "$SCRIPT_DIR/lib/env-perm.sh"
( set -a; . "$ROOT_DIR/.env"; set +a; ENV_FILE="$ROOT_DIR/.env"; assert_no_placeholder ) || exit 1
# shellcheck source=./lib/db-engines.sh
. "$SCRIPT_DIR/lib/db-engines.sh"

ENGINE_REQ=""
if [ -n "$ENGINE_ARG" ]; then
    ENGINE_REQ="$(db_parse_engines "$ENGINE_ARG")" || usage
fi

# APPLY_EXPORTS — extra shell lines apply_module runs after sourcing .env. Only
#   the database module sets any: the engine list worked out further down.
APPLY_EXPORTS=""

# has_managed_state <module> — true when the prefix's workspace of the module tracks a
#   real resource. Data sources are filtered out, and outputs are ignored: a module whose
#   resources were removed from state can keep stale outputs, which would otherwise read
#   as "already prepared".
has_managed_state() {
    local mod="$1" out
    out="$(ws_exec bash -c '
        cd "/work/'"$mod"'" 2>/dev/null || exit 0
        tofu state list 2>/dev/null || true
    ' | grep -v '^data\.' || true)"
    [ -n "$(printf %s "$out" | tr -d '[:space:]')" ]
}

# apply_module <module> [show_outputs] — init + validate + apply inside the runner
apply_module() {
    local mod="$1" show="${2:-yes}"
    ws_exec bash -c '
        set -euo pipefail
        set -a; . /work/.env; set +a
        export VAULT_ADDR=http://openbao:8200
        '"$APPLY_EXPORTS"'
        mkdir -p /work/.tofu-plugin-cache /work/ssh_keys
        cd "/work/'"$mod"'"
        '"$WS_INIT"'
        tofu validate
        tofu apply -auto-approve
        if [ "'"$show"'" = "yes" ]; then
            echo
            echo "=================== OUTPUTS (connection info) ==================="
            tofu output
        fi
    '
}

# bucket_owners — "<prefix> <bucket_name>" for every OTHER prefix whose bucket module
#   holds a bucket. Read straight from the state files: tofu can only read one
#   workspace at a time, and this runs before any apply.
bucket_owners() {
    docker exec "$RUNNER" bash -c '
        cd "/work/tofu/'"$CSP"'/bucket" 2>/dev/null || exit 0
        for f in terraform.tfstate.d/*/terraform.tfstate; do
            [ -f "$f" ] || continue
            ws="${f#terraform.tfstate.d/}"; ws="${ws%/terraform.tfstate}"
            [ "$ws" = "'"$WS_PREFIX"'" ] && continue
            name="$(jq -r ".outputs.bucket_name.value // empty" "$f" 2>/dev/null || true)"
            [ -n "$name" ] && printf "%s %s\n" "$ws" "$name"
        done
    ' || true
}

# check_bucket_name — refuse an empty bucket name, or one another prefix already uses.
#   The bucket is the one resource whose name is not derived from the prefix, so two
#   environments share it unless .env is changed as well. Left to the apply, AWS
#   answers BucketAlreadyOwnedByYou and NCP a conflict, neither of which says which
#   environment owns it. An empty name is worse: the AWS provider makes one up
#   (terraform-...), so a bucket nobody named would be created.
check_bucket_name() {
    local var="TF_VAR_${CSP}_bucket_name" name owner other
    name="$( set -a; . "$ROOT_DIR/.env" 2>/dev/null; set +a; printf %s "${!var:-}" )"
    if [ -z "$name" ]; then
        echo -e "${RED}=== ${var} is empty ===${NC}" >&2
        echo "  Set a bucket name of your own in .env before preparing the bucket." >&2
        exit 1
    fi
    while read -r owner other; do
        [ -n "$owner" ] || continue
        if [ "$other" = "$name" ]; then
            echo -e "${RED}=== bucket '${name}' already belongs to prefix '${owner}' ===${NC}" >&2
            echo "  The bucket name is not derived from the prefix, so each environment needs" >&2
            echo "  its own. Set another ${var} in .env for prefix '${WS_PREFIX}'." >&2
            exit 1
        fi
    done <<< "$(bucket_owners)"
}

# Already prepared? Report it and stop, so a repeated command is a no-op instead of
# a fresh apply. Tracking a resource is the signal; it does not prove the module applied
# cleanly to the end, which is why --force exists to re-apply and converge one that
# stopped halfway.
# already_prepared <what> <hint-args> — report a no-op run and stop.
already_prepared() {
    echo -e "${YELLOW}=== ${1} (prefix ${WS_PREFIX}) is already prepared - nothing to do ===${NC}"
    ws_exec bash -c '
        cd "/work/'"$MODULE"'"
        tofu output 2>/dev/null || true
    ' | sed 's/^/  /'
    echo
    echo "  Connection info  :  ./scripts/conn-info.sh ${CSP} ${RESOURCE} --prefix ${WS_PREFIX}"
    echo "  Re-apply anyway  :  ./scripts/prepare.sh ${CSP} ${RESOURCE}${2} --force"
    echo "  Destroy          :  ./scripts/teardown.sh ${CSP} ${RESOURCE}${2}"
    exit 0
}

if [ "$RESOURCE" = "database" ]; then
    # The engines tofu is asked to run. Existing ones are always kept: the module
    # is declarative, so an engine left out of the list would be destroyed.
    CURRENT="$(db_state_engines "$MODULE")"
    if [ -n "$ENGINE_REQ" ]; then
        if [ "$FORCE" -eq 0 ] && [ -z "$(db_minus "$ENGINE_REQ" "$CURRENT")" ]; then
            already_prepared "${CSP}/database $(db_cli_names "$ENGINE_REQ")" \
                " --engine $(db_cli_names "$ENGINE_REQ" | tr ' ' ',')"
        fi
        TARGET="$(db_union "$CURRENT" "$ENGINE_REQ")"
    elif [ "$FORCE" -eq 1 ] && [ -n "$CURRENT" ]; then
        TARGET="$CURRENT"
    else
        TARGET="$(db_all_engines)"
    fi
    APPLY_EXPORTS="$(db_engines_export "$TARGET")"
fi

if [ "$FORCE" -eq 0 ] && [ -z "$ENGINE_REQ" ] && has_managed_state "$MODULE"; then
    already_prepared "${CSP}/${RESOURCE}" ""
fi

if [ "$RESOURCE" = "bucket" ]; then
    check_bucket_name
fi

# NCP and Alibaba vm/database resolve the VPC, subnet and security group by name
# from tofu/<csp>/network, so it has to exist first. It is applied here rather than
# exposed as a command. The network lives in the same prefix's workspace, which is
# what keeps the by-name lookups matching: the names embed the prefix the workspace
# is named after.
if { [ "$CSP" = "ncp" ] || [ "$CSP" = "alibaba" ]; } && { [ "$RESOURCE" = "vm" ] || [ "$RESOURCE" = "database" ]; }; then
    if ! has_managed_state "tofu/${CSP}/network"; then
        case "$CSP" in
            ncp)     NET_WHAT="VPC + PUBLIC subnet + ACG" ;;
            alibaba) NET_WHAT="VPC + vSwitch + security group" ;;
        esac
        echo -e "${YELLOW}=== prerequisite: creating ${CSP}/network (${NET_WHAT}) ===${NC}"
        apply_module "tofu/${CSP}/network" no
        echo -e "${GREEN}${CSP}/network ready.${NC}"
        echo
    fi
fi

# alibaba_cli <args...> — run the Alibaba Cloud CLI in the runner with the keys
#   from OpenBao, handed over as environment variables for this one call. Exit 3:
#   the runner has no CLI (built before it was added), 4: OpenBao unreadable.
alibaba_cli() {
    local region
    region="$( set -a; . "$ROOT_DIR/.env" 2>/dev/null; set +a; printf %s "${TF_VAR_alibaba_region:-ap-northeast-2}" )"
    docker exec -e R="$region" "$RUNNER" bash -c '
        set -euo pipefail
        command -v aliyun >/dev/null 2>&1 || exit 3
        sec="$(curl -sf -H "X-Vault-Token: ${VAULT_TOKEN:-}" http://openbao:8200/v1/secret/data/csp/alibaba)" || exit 4
        ALIBABA_CLOUD_ACCESS_KEY_ID="$(jq -r ".data.data.ALIBABA_ACCESS_KEY_ID // empty" <<<"$sec")"
        ALIBABA_CLOUD_ACCESS_KEY_SECRET="$(jq -r ".data.data.ALIBABA_ACCESS_KEY_SECRET // empty" <<<"$sec")"
        export ALIBABA_CLOUD_ACCESS_KEY_ID ALIBABA_CLOUD_ACCESS_KEY_SECRET ALIBABA_CLOUD_REGION_ID="$R"
        aliyun "$@" --RegionId "$R"
    ' _ "$@"
}

# alibaba_pg_slr — make sure AliyunServiceRoleForRdsPgsqlOnEcs exists before RDS
#   PostgreSQL is created; see "Alibaba notes" above. Checked first, so an account
#   that has it is left alone and the create call needs no permission there.
PG_SLR="AliyunServiceRoleForRdsPgsqlOnEcs"
alibaba_pg_slr() {
    local out rc=0 has
    out="$(alibaba_cli rds CheckServiceLinkedRole --ServiceLinkedRole "$PG_SLR" 2>&1)" || rc=$?
    case "$rc" in
        0) ;;
        3) echo -e "${RED}The runner has no Alibaba Cloud CLI (aliyun), needed to check ${PG_SLR}.${NC}" >&2
           echo "  Rebuild it: docker compose build tofu-runner && ./scripts/up.sh" >&2
           exit 1 ;;
        4) echo -e "${RED}Cannot read secret/csp/alibaba from OpenBao - is it unsealed? (./scripts/up.sh)${NC}" >&2
           exit 1 ;;
        *) echo -e "${RED}Checking the service-linked role ${PG_SLR} failed:${NC}" >&2
           echo "$out" | sed 's/^/  /' >&2
           exit 1 ;;
    esac
    has="$(printf '%s' "$out" | jq -r '.HasServiceLinkedRole // empty' 2>/dev/null || true)"
    if [ "$has" = "true" ]; then
        return 0
    fi
    echo -e "${YELLOW}=== prerequisite: creating the service-linked role ${PG_SLR} ===${NC}"
    echo "  RDS PostgreSQL needs it to attach network interfaces. It is free, account-wide"
    echo "  and created once; teardown.sh leaves it in place."
    if ! out="$(alibaba_cli rds CreateServiceLinkedRole --ServiceLinkedRole "$PG_SLR" 2>&1)"; then
        echo -e "${RED}Creating ${PG_SLR} failed:${NC}" >&2
        echo "$out" | sed 's/^/  /' >&2
        echo "  The RAM user needs ram:CreateServiceLinkedRole. Or create it once in the console:" >&2
        echo "  the RDS PostgreSQL purchase page asks to authorize it (SLR Authorization)." >&2
        exit 1
    fi
    echo -e "${GREEN}${PG_SLR} created.${NC}"
    echo
}

if [ "$CSP" = "alibaba" ] && [ "$RESOURCE" = "database" ] && db_has "$TARGET" postgres; then
    alibaba_pg_slr
fi

echo -e "${CYAN}=== prepare: ${CSP}/${RESOURCE} (prefix ${WS_PREFIX}) ===${NC}"
if [ "$RESOURCE" = "database" ]; then
    echo "  engines : $(db_cli_names "$TARGET")"
    if [ -n "$CURRENT" ]; then
        echo "  (already running: $(db_cli_names "$CURRENT"); they stay)"
    fi
fi
if [ "$CSP" = "ncp" ] && [ "$RESOURCE" = "database" ]; then
    echo -e "${YELLOW}Managed DB creation takes ~30 minutes. Do not interrupt this command.${NC}"
fi

apply_module "$MODULE"
echo -e "${GREEN}=== done: ${CSP}/${RESOURCE} (prefix ${WS_PREFIX}) ===${NC}"
echo "  Reveal a sensitive output (password, connection_uri, ...):"
echo "    docker exec -e TF_WORKSPACE=${WS_PREFIX} ${RUNNER} bash -c 'cd /work/${MODULE} && tofu output -raw <output_name>'"
echo "  Every prepared environment, all prefixes:  ./scripts/list.sh"

if [ "$CSP" = "ncp" ] && [ "$RESOURCE" = "database" ]; then
    echo
    echo -e "${YELLOW}Next step — managed DBs are not reachable from outside yet.${NC}"
    echo "  A public domain must be issued once per DB server in the NCP console:"
    echo "    Database > Cloud DB for <engine> > select the DB server > DB Management > Public domain"
    echo "  Then reflect and verify it with:  ./scripts/ncp-db-domain.sh"
fi
