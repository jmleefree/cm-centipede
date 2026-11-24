#!/usr/bin/env bash
# ==============================================================================
# gcp-db-versions.sh — list what GCP offers in TF_VAR_gcp_region: Cloud SQL
#                      versions and tiers, zones, machine types and Ubuntu
#                      image families
# ------------------------------------------------------------------------------
#   ./scripts/gcp-db-versions.sh [mysql [regex]|postgresql [regex]|server [regex]|all]
#
#   Why:
#     Cloud SQL names a version together with its engine (MYSQL_8_4) where .env
#     takes the number alone (TF_VAR_gcp_mysql_version=8.4), and a machine type
#     is sold per zone. This lists them in the form .env takes.
#
#   How it works:
#     google has no data source for Cloud SQL versions or tiers, so the REST APIs
#     are called directly, read-only (GET), from the runner. A token is requested
#     for the service account in OpenBao secret/csp/gcp: a JWT is signed with its
#     private key (openssl) and traded at oauth2.googleapis.com. Then
#       sqladmin  /v1/flags                       versions (every flag's appliesTo)
#       sqladmin  /v1/projects/<p>/tiers          predefined tiers
#       compute   regions/<region>                zones
#       compute   zones/<zone>/machineTypes       machine types of TF_VAR_gcp_zone
#       compute   projects/ubuntu-os-cloud/images image families
#     Only curl, jq and openssl are needed - nothing is installed or created. The
#     replies are filtered in the runner; the key and the token never leave it.
#     An API that is not enabled on the project is reported as such.
#
#   [regex]:
#     Filters the tier names (mysql / postgresql, default: all) or the machine
#     types (server, default ^e2-, the general-purpose family a test VM needs), e.g.
#       ./scripts/gcp-db-versions.sh mysql 'g1|f1'
#       ./scripts/gcp-db-versions.sh server '^n2d-'
#     `all` uses the defaults.
#
#   Not listed:
#     - db-custom-<vCPU>-<memory MB> tiers: they are built to measure rather than
#       listed; the rules are printed instead.
#     - Which versions are in extended support (billed on top): the API does not
#       say. See https://cloud.google.com/sql/docs/db-versions.
# ==============================================================================
set -euo pipefail

RUNNER="tofuenv-runner"
GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'; NC='\033[0m'

usage() { echo "Usage: $0 [mysql [regex]|postgresql [regex]|server [regex]|all]" >&2; exit 1; }

WHAT="${1:-all}"
TIER_FILTER="."
VM_FILTER="^e2-"
case "$WHAT" in
    mysql|postgresql) TIER_FILTER="${2:-$TIER_FILTER}" ;;
    server)           VM_FILTER="${2:-$VM_FILTER}" ;;
esac
case "$WHAT" in
    mysql|postgresql|server|all) ;;
    -h|--help) usage ;;
    *) echo -e "${RED}unknown argument: $WHAT${NC}" >&2; usage ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! docker ps --format '{{.Names}}' | grep -q "^${RUNNER}$"; then
    echo -e "${RED}The ${RUNNER} container is not running. Run ./scripts/up.sh first.${NC}" >&2; exit 1
fi

# env_val <name> <default> — a value .env sets, for the queries and the titles.
env_val() { ( set -a; . "$ROOT_DIR/.env" 2>/dev/null; set +a; v="$1"; printf %s "${!v:-$2}" ); }
REGION="$(env_val TF_VAR_gcp_region asia-northeast3)"
ZONE="$(env_val TF_VAR_gcp_zone "${REGION}-a")"
IMAGE_PROJECT="$(env_val TF_VAR_gcp_image_project ubuntu-os-cloud)"
MYSQL_VER="$(env_val TF_VAR_gcp_mysql_version 8.4)"
PG_VER="$(env_val TF_VAR_gcp_postgres_version 16)"

echo -e "${CYAN}=== querying GCP in ${REGION} / ${ZONE} (read-only API calls, nothing is created) ===${NC}"

# The runner does the calls and the filtering, and prints one small JSON object.
# Exit 3: OpenBao unreadable, 4: no token (the reply's error is printed).
rc=0
JSON="$(docker exec -e R="$REGION" -e Z="$ZONE" -e IP="$IMAGE_PROJECT" -e VMRE="$VM_FILTER" "$RUNNER" bash -c '
    set -euo pipefail
    umask 077
    sec="$(curl -sf -H "X-Vault-Token: ${VAULT_TOKEN:-}" http://openbao:8200/v1/secret/data/csp/gcp)" || exit 3
    k() { jq -r ".data.data.$1 // empty" <<<"$sec"; }

    # The replies go to files, not variables: the image list runs long. Removed
    # on the way out, the key file with them.
    D="$(mktemp -d)"; trap "rm -rf \"$D\"" EXIT

    # A JWT for the service account, signed RS256 with its key. The key is kept
    # in secret/csp/gcp with literal \n (cb-tumblebug format); PEM needs newlines.
    b64() { base64 -w0 | tr "+/" "-_" | tr -d "="; }
    k GCP_PRIVATE_KEY | sed "s/\\\\n/\n/g" > "$D/key.pem"
    now="$(date +%s)"
    hdr="$(jq -cn --arg kid "$(k GCP_PRIVATE_KEY_ID)" "{alg:\"RS256\",typ:\"JWT\",kid:\$kid}" | b64)"
    clm="$(jq -cn --arg iss "$(k GCP_CLIENT_EMAIL)" --argjson iat "$now" \
        "{iss:\$iss,scope:\"https://www.googleapis.com/auth/cloud-platform\",aud:\"https://oauth2.googleapis.com/token\",iat:\$iat,exp:(\$iat+600)}" | b64)"
    sig="$(printf "%s.%s" "$hdr" "$clm" | openssl dgst -sha256 -sign "$D/key.pem" -binary | b64)" || exit 4
    rm -f "$D/key.pem"
    reply="$(curl -s -X POST https://oauth2.googleapis.com/token \
        --data-urlencode grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer \
        --data-urlencode "assertion=${hdr}.${clm}.${sig}")"
    TOK="$(jq -r ".access_token // empty" <<<"$reply")"
    if [ -z "$TOK" ]; then jq -r ".error_description // .error // ." <<<"$reply" >&2; exit 4; fi
    P="$(k GCP_PROJECT_ID)"

    # get <file> <url> — one GET. The body is kept on an HTTP error too: it holds
    # the reason (SERVICE_DISABLED, PERMISSION_DENIED), which is reported.
    get() {
        curl -s -H "Authorization: Bearer $TOK" "$2" -o "$D/$1" || printf "{}" > "$D/$1"
        [ -s "$D/$1" ] || printf "{}" > "$D/$1"
    }
    # get_all <file> <url> — every page of a compute list, its items merged.
    get_all() {
        local url="$2" tok="" n=0
        printf "[]" > "$D/$1"
        while :; do
            get "page.json" "${url}&maxResults=500${tok:+&pageToken=$tok}"
            if jq -e ".error" "$D/page.json" >/dev/null; then cp "$D/page.json" "$D/$1"; return; fi
            jq -s ".[0] + (.[1].items // [])" "$D/$1" "$D/page.json" > "$D/merge.json" && mv "$D/merge.json" "$D/$1"
            tok="$(jq -r ".nextPageToken // empty" "$D/page.json")"
            n=$((n + 1)); { [ -n "$tok" ] && [ "$n" -lt 20 ]; } || return 0
        done
    }
    CE="https://compute.googleapis.com/compute/v1/projects"
    get     flags.json  "https://sqladmin.googleapis.com/v1/flags"
    get     tiers.json  "https://sqladmin.googleapis.com/v1/projects/$P/tiers"
    get     region.json "$CE/$P/regions/$R"
    get_all mtypes.json "$CE/$P/zones/$Z/machineTypes?"
    get_all images.json "$CE/$IP/global/images?"

    jq -n --slurpfile f "$D/flags.json" --slurpfile t "$D/tiers.json" --slurpfile r "$D/region.json" \
          --slurpfile m "$D/mtypes.json" --slurpfile i "$D/images.json" --arg R "$R" --arg vmre "$VMRE" '"'"'
        $f[0] as $flags | $t[0] as $tiers | $r[0] as $region | $m[0] as $mt | $i[0] as $img |
        def err: if type == "object" and .error then
                   ((.error.details // [] | map(.reason // empty) | first) // .error.status // "")
                   + ": " + (.error.message // "") else null end;
        {
          sql_error: (($flags | err) // ($tiers | err)),
          versions: [ $flags.items[]?.appliesTo[]? ] | unique,
          logbin: [ $flags.items[]? | select(.name == "log_bin_trust_function_creators") | .appliesTo[]? ],
          tiers: [ $tiers.items[]? | select((.region // []) | index($R))
                   | {tier, ram_gb: (((.RAM // "0") | tonumber) / 1073741824 * 100 | round / 100)} ],
          compute_error: (($region | err) // ($mt | err)),
          image_error: ($img | err),
          zones: [ $region.zones[]? | split("/") | last ],
          machines: [ $mt[]? | select(.name | test($vmre))
                      | {name, cpus: .guestCpus, mem_gb: (.memoryMb / 1024 * 100 | round / 100),
                         shared: (.isSharedCpu // false)} ],
          images: [ $img[]? | select(.deprecated == null and (.family // "") != "") | .family ] | unique
        }'"'"'
' )" || rc=$?

case "$rc" in
    0) ;;
    3) echo -e "${RED}Cannot read secret/csp/gcp from OpenBao - is it unsealed, and registered? (./scripts/up.sh)${NC}" >&2; exit 1 ;;
    4) echo -e "${RED}Google refused the token request for the service account (see above).${NC}" >&2; exit 1 ;;
    *) echo -e "${RED}The GCP queries failed (exit ${rc}).${NC}" >&2; exit 1 ;;
esac

# print_lines <title> <jq program over $JSON producing lines>
print_lines() {
    local title="$1" body
    body="$(printf '%s' "$JSON" | jq -r "$2")"
    echo -e "${GREEN}${title}${NC}"
    if [ -z "$body" ]; then echo "  (none)"; else printf '%s\n' "$body"; fi
    echo
}

# api_error <field> <api> — report an API the project refuses; true when it did.
api_error() {
    local e
    e="$(printf '%s' "$JSON" | jq -r ".$1 // empty")"
    [ -n "$e" ] || return 1
    echo -e "${YELLOW}The ${2} answered: ${e}${NC}"
    case "$e" in
        SERVICE_DISABLED*|*"has not been used"*|*"is disabled"*)
            echo -e "${YELLOW}  Enable it: gcloud services enable ${2%% *} (see .env.example)${NC}" ;;
        *PERMISSION_DENIED*|*"not authorized"*|*notAuthorized*)
            echo -e "${YELLOW}  The service account lacks a role for it (Editor, or the matching Admin role).${NC}" ;;
    esac
    echo
    return 0
}

# engine_versions <MYSQL|POSTGRES> — the versions of one engine, in the form
#   .env takes: MYSQL_8_4 -> 8.4, POSTGRES_16 -> 16. A pinned minor version
#   (MYSQL_8_0_31) is left out: the module takes major.minor only.
engine_versions() {
    printf '%s' "$JSON" | jq -r --arg e "$1" '
        .versions[] | select(startswith($e + "_")) | ltrimstr($e + "_")
        | select(test("^[0-9]+(_[0-9]+)?$")) | gsub("_"; ".")' \
        | sort -t. -k1,1n -k2,2n | sed 's/^/  /'
}

tiers() {
    print_lines "Predefined Cloud SQL tiers in ${REGION} matching /${TIER_FILTER}/ (TF_VAR_gcp_${1}_tier)" \
        "[.tiers[] | select(.tier | test(\"${TIER_FILTER}\"))] | sort_by(.ram_gb, .tier)
         | map(\"  \(.tier)  ->  \(.ram_gb) GB\"
               + (if .tier | test(\"optimized\") then \"  [Enterprise Plus only - refused by the module]\" else \"\" end))
         | join(\"\n\")"
    echo -e "${YELLOW}  The module runs the Enterprise edition; the *-optimized-* tiers belong to Enterprise Plus.${NC}"
    echo
    echo -e "${GREEN}Custom tiers (Enterprise edition): db-custom-<vCPU>-<memory MB>${NC}"
    echo "  vCPU 1 or an even number up to 96; memory 0.9-6.5 GB per vCPU, a multiple of 256 MB"
    echo "  e.g. db-custom-1-3840 (1 vCPU / 3.75 GB), db-custom-2-7680 (2 vCPU / 7.5 GB)"
    echo "  db-f1-micro / db-g1-small are shared-core: cheaper, no SLA."
    echo
}

mysql() {
    api_error sql_error "sqladmin.googleapis.com (Cloud SQL Admin API)" && return 0
    local body
    body="$(engine_versions MYSQL)"
    echo -e "${GREEN}Cloud SQL for MySQL versions (TF_VAR_gcp_mysql_version, .env sets ${MYSQL_VER})${NC}"
    if [ -z "$body" ]; then echo "  (none)"; else printf '%s\n' "$body"; fi
    if printf '%s' "$JSON" | jq -e --arg v "MYSQL_${MYSQL_VER//./_}" '.logbin | index($v) | not' >/dev/null; then
        echo -e "${YELLOW}  log_bin_trust_function_creators is not listed for MYSQL_${MYSQL_VER//./_}; the module sets it.${NC}"
    fi
    echo
    tiers mysql
}

postgresql() {
    api_error sql_error "sqladmin.googleapis.com (Cloud SQL Admin API)" && return 0
    local body
    body="$(engine_versions POSTGRES)"
    echo -e "${GREEN}Cloud SQL for PostgreSQL versions (TF_VAR_gcp_postgres_version, .env sets ${PG_VER})${NC}"
    if [ -z "$body" ]; then echo "  (none)"; else printf '%s\n' "$body"; fi
    echo
    tiers postgres
}

server() {
    api_error compute_error "compute.googleapis.com (Compute Engine API)" && return 0
    print_lines "Zones in ${REGION} (TF_VAR_gcp_zone)" \
        '.zones | sort | map("  " + .) | join("\n")'
    print_lines "Machine types matching /${VM_FILTER}/ in ${ZONE} (TF_VAR_gcp_machine_type)" \
        '.machines | sort_by(.cpus, .mem_gb, .name)
         | map("  \(.name)  ->  \(.cpus) vCPU / \(.mem_gb) GB" + (if .shared then "  (shared core)" else "" end))
         | join("\n")'
    if ! api_error image_error "compute.googleapis.com (images of ${IMAGE_PROJECT})"; then
        print_lines "Image families in ${IMAGE_PROJECT} (TF_VAR_gcp_image_family; the latest image of it is used)" \
            '.images | map(select(test("^ubuntu"))) | map("  " + .) | join("\n")'
    fi
}

case "$WHAT" in
    mysql)      mysql ;;
    postgresql) postgresql ;;
    server)     server ;;
    all)        mysql; postgresql; server ;;
esac

echo -e "${YELLOW}Copy the values into .env (TF_VAR_gcp_*). Versions are the number alone; a version past${NC}"
echo -e "${YELLOW}its community end of life is in Cloud SQL extended support, billed on top.${NC}"
