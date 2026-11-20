#!/usr/bin/env bash
# ==============================================================================
# azure-db-versions.sh — list what Azure sells in TF_VAR_azure_region: MySQL and
#                        PostgreSQL Flexible Server versions and SKUs, MongoDB
#                        vCore availability, VM sizes and Ubuntu images
# ------------------------------------------------------------------------------
#   ./scripts/azure-db-versions.sh [mysql [regex]|postgresql [regex]|mongodb|server [regex]|all]
#
#   Why:
#     A Flexible Server SKU is sold per edition (Burstable, GeneralPurpose,
#     MemoryOptimized) and version, and a VM size can be withheld from a
#     subscription in a region (NotAvailableForSubscription). This lists what the
#     subscription can actually create, in the names .env takes
#     (TF_VAR_azure_mysql_sku=B_Standard_B1ms and so on).
#
#   How it works:
#     azurerm has no data source for any of this, so the ARM REST API is called
#     directly, read-only (GET), from the runner: a token is requested for the
#     service principal in OpenBao secret/csp/azure, then
#       Microsoft.DBforMySQL      locations/<region>/capabilities
#       Microsoft.DBforPostgreSQL locations/<region>/capabilities
#       Microsoft.DocumentDB      provider (mongoClusters regions)
#       Microsoft.Compute         skus, and the Canonical image SKUs of
#                                 TF_VAR_azure_image_offer
#     Only curl and jq are needed - nothing is installed, configured or created.
#     The large replies are filtered in the runner; the token never leaves it.
#
#   [regex]:
#     The lists run to hundreds of entries, so they are filtered by name. The
#     defaults are the families a test environment needs - ^B_ for the MySQL
#     SKUs, ^(B|GP)_ for the PostgreSQL SKUs (General Purpose is the fallback
#     when a region runs out of Burstable), ^Standard_B for the VM sizes. Pass
#     another regex for more, e.g.
#       ./scripts/azure-db-versions.sh mysql '^GP_'
#       ./scripts/azure-db-versions.sh server 'Standard_D.*s_v5'
#     `all` uses the defaults.
#
#   MongoDB vCore (Azure DocumentDB):
#     Azure has no API listing the versions or tiers it sells - not in the REST
#     API (serverVersion is a free string there), not in the az CLI (whose
#     documentdb extension is generated from the same API). What can be shown:
#       - whether the region sells it, from the Microsoft.DocumentDB provider;
#       - the versions and tiers tofu accepts: azurerm checks both against a
#         fixed list, read here from the source of the azurerm version
#         tofu/azure/*/.terraform.lock.hcl pins, at github.com (public, no
#         login). Anything else is refused at plan time. It says nothing about
#         what the region sells, and needs github.com to be reachable;
#       - the version and tier of the clusters already in the subscription.
#
#   PostgreSQL SKUs azurerm refuses:
#     azurerm checks the PostgreSQL sku_name against a fixed regex, and Azure
#     sells SKUs it does not know yet (the B*_v2 burstable family, for one).
#     The regex is read from the same azurerm source as above and each listed
#     SKU it refuses is marked; such a SKU fails at plan time. MySQL sku_name is
#     not checked by azurerm.
# ==============================================================================
set -euo pipefail

RUNNER="tofuenv-runner"
GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'; NC='\033[0m'

usage() { echo "Usage: $0 [mysql [regex]|postgresql [regex]|mongodb|server [regex]|all]" >&2; exit 1; }

WHAT="${1:-all}"
DB_FILTER="^B_"
PG_FILTER="^(B|GP)_"
VM_FILTER="^Standard_B"
case "$WHAT" in
    mysql)            DB_FILTER="${2:-$DB_FILTER}" ;;
    postgresql)       PG_FILTER="${2:-$PG_FILTER}" ;;
    server)           VM_FILTER="${2:-$VM_FILTER}" ;;
esac
case "$WHAT" in
    mysql|postgresql|mongodb|server|all) ;;
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
REGION="$(env_val TF_VAR_azure_region koreacentral)"
OFFER="$(env_val TF_VAR_azure_image_offer 0001-com-ubuntu-server-jammy)"
MYSQL_VER="$(env_val TF_VAR_azure_mysql_version 8.0.21)"
PG_VER="$(env_val TF_VAR_azure_postgres_version 14)"

echo -e "${CYAN}=== querying Azure in ${REGION} (read-only ARM API calls, nothing is created) ===${NC}"

# The runner does the calls and the filtering, and prints one small JSON object.
# Exit 3: OpenBao unreadable, 4: no token (the reply's error is printed).
rc=0
JSON="$(docker exec -e L="$REGION" -e OFFER="$OFFER" -e VMRE="$VM_FILTER" "$RUNNER" bash -c '
    set -euo pipefail
    sec="$(curl -sf -H "X-Vault-Token: ${VAULT_TOKEN:-}" http://openbao:8200/v1/secret/data/csp/azure)" || exit 3
    k() { jq -r ".data.data.$1 // empty" <<<"$sec"; }
    reply="$(curl -s -X POST "https://login.microsoftonline.com/$(k AZURE_TENANT_ID)/oauth2/v2.0/token" \
        --data-urlencode grant_type=client_credentials \
        --data-urlencode "client_id=$(k AZURE_CLIENT_ID)" \
        --data-urlencode "client_secret=$(k AZURE_CLIENT_SECRET)" \
        --data-urlencode scope=https://management.azure.com/.default)"
    TOK="$(jq -r ".access_token // empty" <<<"$reply")"
    if [ -z "$TOK" ]; then jq -r ".error_description // ." <<<"$reply" >&2; exit 4; fi
    SUB="$(k AZURE_SUBSCRIPTION_ID)"

    # The replies go to files, not variables: the VM SKU list alone runs to
    # megabytes, past what one argument to jq may hold. Removed on the way out.
    D="$(mktemp -d)"; trap "rm -rf \"$D\"" EXIT
    # get <file> <fallback> <path> — one GET; the fallback stands in on a failure.
    get() {
        curl -sf -H "Authorization: Bearer $TOK" "https://management.azure.com/subscriptions/${SUB}$3" -o "$D/$1" \
            || printf "%s" "$2" > "$D/$1"
    }
    get mysql.json "{}" "/providers/Microsoft.DBforMySQL/locations/$L/capabilities?api-version=2023-12-30"
    get pg.json    "{}" "/providers/Microsoft.DBforPostgreSQL/locations/$L/capabilities?api-version=2024-08-01"
    get docdb.json "{}" "/providers/Microsoft.DocumentDB?api-version=2021-04-01"
    get mongo.json "{}" "/providers/Microsoft.DocumentDB/mongoClusters?api-version=2026-09-01"
    get skus.json  "{}" "/providers/Microsoft.Compute/skus?api-version=2021-07-01&\$filter=location%20eq%20%27$L%27"
    get imgs.json  "[]" "/providers/Microsoft.Compute/locations/$L/publishers/Canonical/artifacttypes/vmimage/offers/$OFFER/skus?api-version=2024-07-01"

    # azurerm spells a Flexible Server SKU as <tier prefix>_<name>.
    jq -n --slurpfile m "$D/mysql.json" --slurpfile p "$D/pg.json" --slurpfile d "$D/docdb.json" \
          --slurpfile s "$D/skus.json" --slurpfile i "$D/imgs.json" --slurpfile c "$D/mongo.json" \
          --arg L "$L" --arg vmre "$VMRE" '"'"'
        $m[0] as $mysql | $p[0] as $pg | $d[0] as $docdb | $s[0] as $skus | $i[0] as $imgs | $c[0] as $mc |
        def pfx: {Burstable: "B_", GeneralPurpose: "GP_", MemoryOptimized: "MO_"}[.] // "";
        def norm: ascii_downcase | gsub(" "; "");
        {
          mysql: [ $mysql.value[]? | select(.zone == "none")
                   | .supportedFlexibleServerEditions[]? | (.name) as $ed
                   | .supportedServerVersions[]? | (.name) as $v
                   | .supportedSkus[]?
                   | {version: $v, sku: (($ed | pfx) + .name), edition: $ed,
                      vcores: .vCores, mem_gb: ((.supportedMemoryPerVCoreMB // 0) * .vCores / 1024)} ],
          mysql_storage: [ $mysql.value[]? | select(.zone == "none")
                   | .supportedFlexibleServerEditions[]?.supportedStorageEditions[]?
                   | {min_gb: (.minStorageSize / 1024), max_gb: (.maxStorageSize / 1024)} ] | unique,
          pg_restricted: ($pg.value[0].restricted // "unknown"),
          pg_versions: [ $pg.value[0].supportedServerVersions[]?.name ],
          pg: [ $pg.value[0].supportedServerEditions[]? | (.name) as $ed
                | .supportedServerSkus[]?
                | {sku: (($ed | pfx) + .name), edition: $ed, vcores: .vCores,
                   mem_gb: ((.supportedMemoryPerVcoreMb // 0) * .vCores / 1024)} ],
          pg_storage_gb: [ $pg.value[0].supportedServerEditions[]?.supportedStorageEditions[]?
                           .supportedStorageMb[]?.storageSizeMb / 1024 ] | unique,
          mongodb: {
            registration: ($docdb.registrationState // "unknown"),
            sold: ([ $docdb.resourceTypes[]? | select(.resourceType == "mongoClusters")
                     | .locations[] | norm ] | index($L | norm) != null),
            clusters: [ $mc.value[]? | {name, location,
                        version: (.properties.serverVersion // "?"),
                        tier: (.properties.compute.tier // "?"),
                        status: (.properties.clusterStatus // "?")} ]
          },
          vm: [ $skus.value[]? | select(.resourceType == "virtualMachines" and (.name | test($vmre)))
                | select((.restrictions // []) | length == 0)
                | (.capabilities | map({(.name): .value}) | add) as $c
                | {name, vcpus: ($c.vCPUs | tonumber), mem_gb: ($c.MemoryGB | tonumber),
                   gens: ($c.HyperVGenerations // "")} ],
          vm_restricted: [ $skus.value[]? | select(.resourceType == "virtualMachines" and (.name | test($vmre)))
                           | select((.restrictions // []) | length > 0) | .name ],
          images: [ $imgs[]?.name ]
        }'"'"'
' )" || rc=$?

case "$rc" in
    0) ;;
    3) echo -e "${RED}Cannot read secret/csp/azure from OpenBao - is it unsealed, and registered? (./scripts/up.sh)${NC}" >&2; exit 1 ;;
    4) echo -e "${RED}Azure refused the token request for the service principal (see above).${NC}" >&2; exit 1 ;;
    *) echo -e "${RED}The Azure queries failed (exit ${rc}).${NC}" >&2; exit 1 ;;
esac

# print_lines <title> <jq program over $JSON producing lines>
print_lines() {
    local title="$1" body
    body="$(printf '%s' "$JSON" | jq -r "$2")"
    echo -e "${GREEN}${title}${NC}"
    if [ -z "$body" ]; then echo "  (none)"; else printf '%s\n' "$body"; fi
    echo
}

# The SKU list needs the version passed in, so it gets its own jq call.
mysql_skus() {
    local body
    body="$(printf '%s' "$JSON" | jq -r --arg v "$MYSQL_VER" --arg re "$DB_FILTER" '
        [.mysql[] | select(.version == $v and (.sku | test($re)))] | unique_by(.sku) | sort_by(.edition, .vcores, .mem_gb)
        | map("  \(.sku)  ->  \(.vcores) vCore / \(.mem_gb) GB  (\(.edition))") | join("\n")')"
    echo -e "${GREEN}MySQL SKUs for ${MYSQL_VER} matching /${DB_FILTER}/ (TF_VAR_azure_mysql_sku)${NC}"
    if [ -z "$body" ]; then echo "  (none - is ${MYSQL_VER} a version listed above, and does the regex match?)"; else printf '%s\n' "$body"; fi
    echo
    print_lines "MySQL storage (TF_VAR_azure_mysql_storage_gb)" \
        '.mysql_storage | map("  \(.min_gb)-\(.max_gb) GB") | join("\n")'
}

mysql_all() {
    print_lines "MySQL Flexible Server versions in ${REGION} (TF_VAR_azure_mysql_version)" \
        '[.mysql[].version] | unique | sort_by(split(".") | map(tonumber? // 0)) | map("  " + .) | join("\n")'
    # Azure may sell a version ahead of the provider: azurerm validates version.
    echo -e "${YELLOW}  azurerm 5.x accepts 5.7, 8.0.21 and 8.4 only; another version listed above is refused at plan time.${NC}"
    echo
    mysql_skus
}

postgresql() {
    if [ "$(printf '%s' "$JSON" | jq -r .pg_restricted)" = "Enabled" ]; then
        echo -e "${YELLOW}PostgreSQL Flexible Server is restricted for this subscription in ${REGION}.${NC}"
        echo
    fi
    print_lines "PostgreSQL Flexible Server versions in ${REGION} (TF_VAR_azure_postgres_version, .env sets ${PG_VER})" \
        '.pg_versions | sort_by(tonumber? // 0) | map("  " + .) | join("\n")'
    # The sku_name regex azurerm validates against; empty when it cannot be read.
    local ver src skure="" note=""
    ver="$(azurerm_version)"
    if [ -z "$ver" ]; then
        note="No tofu/azure module is initialised yet, so the SKUs azurerm refuses are not marked."
    elif ! src="$(curl -sf --max-time 20 "https://raw.githubusercontent.com/hashicorp/terraform-provider-azurerm/v${ver}/internal/services/postgres/validate/flexible_server_sku_name.go")"; then
        note="Could not fetch the azurerm v${ver} source from github.com, so the SKUs it refuses are not marked."
    else
        skure="$(printf '%s' "$src" | grep -o 'MustCompile(`[^`]*`)' | head -1 | sed -E 's/^MustCompile\(`//; s/`\)$//')"
        [ -n "$skure" ] || note="azurerm v${ver} has no sku_name regex where expected, so no SKU is marked."
    fi
    local body
    body="$(printf '%s' "$JSON" | jq -r --arg re "$PG_FILTER" --arg skure "$skure" --arg ver "$ver" '
        [.pg[] | select(.sku | test($re))] | unique_by(.sku) | sort_by(.edition, .vcores, .mem_gb)
        | map("  \(.sku)  ->  \(.vcores) vCore / \(.mem_gb) GB  (\(.edition))"
              + (if $skure != "" and (.sku | test($skure) | not) then "  [refused by azurerm v\($ver)]" else "" end))
        | join("\n")')"
    echo -e "${GREEN}PostgreSQL SKUs matching /${PG_FILTER}/ (TF_VAR_azure_postgres_sku)${NC}"
    if [ -z "$body" ]; then echo "  (none)"; else printf '%s\n' "$body" | sed -E "s/(\[refused by azurerm[^]]*\])/$(printf '\033[0;33m')\1$(printf '\033[0m')/"; fi
    if [ -n "$note" ]; then
        echo -e "${YELLOW}  ${note}${NC}"
    elif printf '%s' "$body" | grep -q 'refused by azurerm'; then
        echo -e "${YELLOW}  Azure sells the SKUs marked [refused by azurerm], but tofu rejects them at plan time.${NC}"
    fi
    echo
    print_lines "PostgreSQL storage sizes in GB (TF_VAR_azure_postgres_storage_gb)" \
        '.pg_storage_gb | map(tostring) | "  " + join(", ")'
}

# azurerm_version — the azurerm version the Azure modules' lock file pins, empty
#   when no module has been initialised yet.
azurerm_version() {
    local m lock
    for m in database vm bucket; do
        lock="$ROOT_DIR/tofu/azure/$m/.terraform.lock.hcl"
        [ -f "$lock" ] || continue
        sed -n '/"registry.opentofu.org\/hashicorp\/azurerm"/,/^}/s/^ *version *= *"\([^"]*\)".*/\1/p' "$lock" | head -1
        return 0
    done
}

# azurerm_allowed <source> <attribute> — the values azurerm's StringInSlice
#   accepts for one attribute of azurerm_mongo_cluster, space-separated; empty
#   when the attribute is not validated that way in this version.
azurerm_allowed() {
    printf '%s' "$1" | awk -v attr="\"$2\": {" '
        index($0, attr)                 { inattr = 1; next }
        inattr && /StringInSlice/       { inlist = 1; next }
        inattr && !inlist && /^\t\t},?$/ { exit }
        inlist && /}, false\)/          { exit }
        inlist { gsub(/[\t ",]/, ""); if ($0 != "") printf "%s ", $0 }'
}

mongodb() {
    local sold reg ver src versions tiers
    sold="$(printf '%s' "$JSON" | jq -r .mongodb.sold)"
    reg="$(printf '%s' "$JSON" | jq -r .mongodb.registration)"
    echo -e "${GREEN}Azure DocumentDB (Cosmos DB for MongoDB vCore) in ${REGION}${NC}"
    if [ "$sold" = "true" ]; then echo "  sold in ${REGION}"; else echo -e "  ${YELLOW}not sold in ${REGION}${NC}"; fi
    echo "  Microsoft.DocumentDB on this subscription: ${reg}"
    echo

    # What tofu accepts, from the azurerm source of the version that is installed.
    ver="$(azurerm_version)"
    if [ -z "$ver" ]; then
        echo -e "${YELLOW}No tofu/azure module is initialised yet, so the azurerm version is unknown.${NC}"
        echo "  Run ./scripts/prepare.sh azure <resource> once, then this again."
        echo
    elif ! src="$(curl -sf --max-time 20 "https://raw.githubusercontent.com/hashicorp/terraform-provider-azurerm/v${ver}/internal/services/mongocluster/mongo_cluster_resource.go")"; then
        echo -e "${YELLOW}Could not fetch the azurerm v${ver} source from github.com - is it reachable?${NC}"
        echo
    else
        versions="$(azurerm_allowed "$src" version)"
        tiers="$(azurerm_allowed "$src" compute_tier)"
        echo -e "${GREEN}Versions azurerm v${ver} accepts (TF_VAR_azure_mongodb_version)${NC}"
        echo "  ${versions:-(not a fixed list in this version - any string is passed to Azure)}"
        echo
        echo -e "${GREEN}Tiers azurerm v${ver} accepts (TF_VAR_azure_mongodb_tier)${NC}"
        echo "  ${tiers:-(not a fixed list in this version - any string is passed to Azure)}"
        echo "  Free: one per subscription. M10 / M20 / M25 are burstable; once at M30 or above,"
        echo "  a cluster cannot go back down to them."
        echo
        echo -e "${YELLOW}  Azure has no API listing what ${REGION} sells: these are the values tofu lets${NC}"
        echo -e "${YELLOW}  through, not a promise the region has them all.${NC}"
        echo
    fi

    print_lines "MongoDB clusters already in this subscription (what Azure actually built)" \
        '.mongodb.clusters | sort_by(.name)
         | map("  \(.name)  ->  version \(.version), \(.tier), \(.location), \(.status)") | join("\n")'
}

server() {
    print_lines "VM sizes matching /${VM_FILTER}/ the subscription can use in ${REGION} (TF_VAR_azure_vm_size)" \
        '.vm | sort_by(.vcpus, .mem_gb, .name)
         | map("  \(.name)  ->  \(.vcpus) vCPU / \(.mem_gb) GB, Hyper-V gen \(.gens)") | join("\n")'
    local n
    n="$(printf '%s' "$JSON" | jq '.vm_restricted | length')"
    if [ "$n" -gt 0 ]; then
        print_lines "Matching sizes NOT available to this subscription in ${REGION}" \
            '.vm_restricted | sort | map("  " + .) | join("\n")'
    fi
    print_lines "Canonical ${OFFER} image SKUs (TF_VAR_azure_image_sku; a *-gen2 SKU needs a size with gen V2)" \
        '.images | sort | map("  " + .) | join("\n")'
}

case "$WHAT" in
    mysql)      mysql_all ;;
    postgresql) postgresql ;;
    mongodb)    mongodb ;;
    server)     server ;;
    all)        mysql_all; postgresql; mongodb; server ;;
esac

echo -e "${YELLOW}Copy the values into .env (TF_VAR_azure_*). The SKUs are in the <tier>_<size>${NC}"
echo -e "${YELLOW}form azurerm takes; change the MySQL version, then run this again for its SKUs.${NC}"
