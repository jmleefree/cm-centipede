#!/usr/bin/env bash
# ==============================================================================
# alibaba-db-versions.sh — list the Alibaba zones, RDS versions and classes,
#                          and ECS types and images
# ------------------------------------------------------------------------------
#   ./scripts/alibaba-db-versions.sh [zones|mysql|mariadb|postgresql|mongodb|server|all]
#
#   Why:
#     ECS, RDS and MongoDB all go in the one vSwitch of TF_VAR_alibaba_zone, so
#     the zone has to sell every one of them. And an RDS instance class is only
#     sold for a given engine version, edition (Basic / HighAvailability),
#     storage type and zone together - tofu/alibaba/database refuses a class
#     that is not, at plan time. This lists what fits the values .env sets.
#     Change a version, edition or the zone in .env, then run this again.
#
#   How it works:
#     tofu/alibaba/versions only holds data sources (it creates nothing), so
#     applying it is safe and free.
#
#   MongoDB:
#     The provider has no data source for MongoDB versions or classes, so they
#     come from the Alibaba Cloud CLI in the runner instead: one read-only
#     `aliyun dds DescribeAvailableResource` call for a pay-as-you-go replica set
#     in TF_VAR_alibaba_zone on TF_VAR_alibaba_mongodb_storage_type. The keys are
#     read from OpenBao for that one call and handed to the CLI as environment
#     variables; nothing is configured or written. A runner built before the CLI
#     was added to Dockerfile.tofu-runner is told to rebuild.
# ==============================================================================
set -euo pipefail

RUNNER="tofuenv-runner"
MODULE="tofu/alibaba/versions"
GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'; NC='\033[0m'

usage() { echo "Usage: $0 [zones|mysql|mariadb|postgresql|mongodb|server|all]" >&2; exit 1; }

WHAT="${1:-all}"
case "$WHAT" in
    zones|mysql|mariadb|postgresql|mongodb|server|all) ;;
    -h|--help) usage ;;
    *) echo -e "${RED}unknown argument: $WHAT${NC}" >&2; usage ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ ! -d "$ROOT_DIR/$MODULE" ]; then
    echo -e "${RED}module not found: $MODULE${NC}" >&2; exit 1
fi
if ! docker ps --format '{{.Names}}' | grep -q "^${RUNNER}$"; then
    echo -e "${RED}The ${RUNNER} container is not running. Run ./scripts/up.sh first.${NC}" >&2; exit 1
fi

echo -e "${CYAN}=== querying Alibaba catalog (data sources only, nothing is created) ===${NC}"
JSON="$(docker exec "$RUNNER" bash -c '
    set -euo pipefail
    set -a; . /work/.env; set +a
    export VAULT_ADDR=http://openbao:8200
    mkdir -p /work/.tofu-plugin-cache
    cd "/work/'"$MODULE"'"
    flock /work/.tofu-plugin-cache/.init.lock tofu init -input=false >/dev/null
    tofu apply -auto-approve >/dev/null
    tofu output -json
')"

ZONE="$(echo "$JSON" | jq -r '.rds_class_filter.value.zone')"

# print_map <title> <jq path to an object> — one "key  ->  value" line per entry.
print_map() {
    local title="$1" path="$2" body
    body="$(echo "$JSON" | jq -r "(${path} // {}) | to_entries | sort_by(.key) | map(\"  \(.key)  ->  \(.value)\") | join(\"\n\")")"
    echo -e "${GREEN}${title}${NC}"
    if [ -z "$body" ]; then echo "  (none)"; else echo "$body"; fi
    echo
}

# print_list <title> <jq path to an array>
print_list() {
    local title="$1" path="$2" body
    body="$(echo "$JSON" | jq -r "(${path} // []) | map(\"  \(.)\") | join(\"\n\")")"
    echo -e "${GREEN}${title}${NC}"
    if [ -z "$body" ]; then echo "  (none)"; else echo "$body"; fi
    echo
}

# zones — each service's zones, then the ones offering all of them.
zones() {
    local svc
    for svc in ecs vswitch mysql mariadb postgresql mongodb; do
        print_list "Zones selling ${svc}" ".zones.value.${svc}"
    done
    print_list "Zones offering ECS, vSwitch and every DB engine (TF_VAR_alibaba_zone)" \
        '.zones.value | [.ecs, .vswitch, .mysql, .mariadb, .postgresql, .mongodb]
           | reduce .[1:][] as $z (.[0]; map(select(. as $x | $z | index($x))))'
    echo -e "  .env sets ${ZONE}."
    echo
}

# rds <engine> — the engine's versions and editions, and its classes.
rds() {
    local e="$1" filter
    filter="$(echo "$JSON" | jq -r --arg e "$e" '.rds_class_filter.value[$e]')"
    print_map "${e} versions in ${ZONE}: version -> editions (TF_VAR_alibaba_${e/postgresql/postgres}_version)" \
        ".rds_versions.value.${e}"
    print_map "${e} classes for ${filter}, $(echo "$JSON" | jq -r '.rds_class_filter.value.storage_type') in ${ZONE} (TF_VAR_alibaba_${e/postgresql/postgres}_instance_class)" \
        ".rds_classes.value.${e}"
}

# env_val <name> <default> — a value .env sets, for titles and the CLI call.
env_val() { ( set -a; . "$ROOT_DIR/.env" 2>/dev/null; set +a; v="$1"; printf %s "${!v:-$2}" ); }

# mongodb — zones from the catalog module, versions and classes from the CLI.
mongodb() {
    local region zone storage ver nodes out rc=0
    region="$(env_val TF_VAR_alibaba_region ap-northeast-2)"
    zone="$(env_val TF_VAR_alibaba_zone ap-northeast-2a)"
    storage="$(env_val TF_VAR_alibaba_mongodb_storage_type cloud_essd1)"
    ver="$(env_val TF_VAR_alibaba_mongodb_version 7.0)"
    nodes="$(env_val TF_VAR_alibaba_mongodb_replication_factor 3)"

    print_list "Zones selling MongoDB" ".zones.value.mongodb"

    # The region is given twice on purpose: --RegionId is the API's parameter,
    # ALIBABA_CLOUD_REGION_ID the CLI's own setting, which it refuses to run without.
    out="$(docker exec -e R="$region" -e Z="$zone" -e S="$storage" "$RUNNER" bash -c '
        set -euo pipefail
        command -v aliyun >/dev/null 2>&1 || exit 3
        sec="$(curl -sf -H "X-Vault-Token: ${VAULT_TOKEN:-}" http://openbao:8200/v1/secret/data/csp/alibaba)" || exit 4
        ALIBABA_CLOUD_ACCESS_KEY_ID="$(jq -r ".data.data.ALIBABA_ACCESS_KEY_ID // empty" <<<"$sec")"
        ALIBABA_CLOUD_ACCESS_KEY_SECRET="$(jq -r ".data.data.ALIBABA_ACCESS_KEY_SECRET // empty" <<<"$sec")"
        export ALIBABA_CLOUD_ACCESS_KEY_ID ALIBABA_CLOUD_ACCESS_KEY_SECRET ALIBABA_CLOUD_REGION_ID="$R"
        aliyun dds DescribeAvailableResource --RegionId "$R" --ZoneId "$Z" \
            --DbType normal --InstanceChargeType PostPaid --StorageType "$S"
    ' 2>&1)" || rc=$?

    case "$rc" in
        0) ;;
        3)
            echo -e "${YELLOW}The runner has no Alibaba Cloud CLI (aliyun): it was built before the CLI${NC}"
            echo -e "${YELLOW}was added. Rebuild it, then run this again:${NC}"
            echo "  docker compose build tofu-runner && ./scripts/up.sh"
            echo
            return 0 ;;
        4)
            echo -e "${RED}Cannot read secret/csp/alibaba from OpenBao - is it unsealed? (./scripts/up.sh)${NC}" >&2
            return 0 ;;
        *)
            echo -e "${RED}aliyun dds DescribeAvailableResource failed:${NC}" >&2
            echo "$out" | sed 's/^/  /' >&2
            echo
            return 0 ;;
    esac

    # Version -> the node counts it is sold with (TF_VAR_alibaba_mongodb_replication_factor).
    echo -e "${GREEN}MongoDB versions in ${zone} on ${storage}: version -> replica set nodes (TF_VAR_alibaba_mongodb_version)${NC}"
    echo "$out" | jq -r '
        [ .SupportedDBTypes.SupportedDBType[]?.AvailableZones.AvailableZone[]?
          .SupportedEngineVersions.SupportedEngineVersion[]?
          | .Version as $v
          | .SupportedEngines.SupportedEngine[]?.SupportedNodeTypes.SupportedNodeType[]?
          | {v: $v, n: .NodeType} ]
        | group_by(.v) | sort_by(.[0].v | split(".") | map(tonumber? // 0))
        | if length == 0 then "  (none)" else
            map("  \(.[0].v)  ->  \(map(.n) | unique | sort_by(tonumber? // 0) | join(", ")) nodes") | join("\n")
          end'
    echo

    # The classes for the version and node count .env sets. The remark comes in
    # Chinese ("2核8GB（独享型）"), so the cores and memory are pulled out of it.
    echo -e "${GREEN}MongoDB classes for ${ver}, ${nodes} nodes, ${storage} in ${zone} (TF_VAR_alibaba_mongodb_instance_class)${NC}"
    echo "$out" | jq -r --arg v "$ver" --arg n "$nodes" '
        [ .SupportedDBTypes.SupportedDBType[]?.AvailableZones.AvailableZone[]?
          .SupportedEngineVersions.SupportedEngineVersion[]? | select(.Version == $v)
          | .SupportedEngines.SupportedEngine[]?.SupportedNodeTypes.SupportedNodeType[]?
          | select(.NodeType == $n) | .AvailableResources.AvailableResource[]? ]
        | unique_by(.InstanceClass)
        | if length == 0 then "  (none)" else
            map(
              (.InstanceClassRemark // "") as $r
              | ($r | capture("(?<c>[0-9]+)核(?<m>[0-9.]+)GB")? // null) as $cm
              | (.DBInstanceStorageRange // {}) as $s
              | "  \(.InstanceClass)  ->  "
                + (if $cm then "\($cm.c) vCPU / \($cm.m) GB" else $r end)
                + (if $s.Min then ", storage \($s.Min)-\($s.Max) GB step \($s.Step)" else "" end)
            ) | join("\n")
          end'
    echo
}

server() {
    print_map "ECS instance types in ${ZONE}, up to 8 vCPUs (TF_VAR_alibaba_instance_type)" ".instance_types.value"
    print_map "Ubuntu system images: name -> size (match one with TF_VAR_alibaba_image_name_regex; the most recent match is used, and TF_VAR_alibaba_vm_volume_size must be at least its size)" ".images.value"
}

case "$WHAT" in
    zones)                    zones ;;
    mysql|mariadb|postgresql) rds "$WHAT" ;;
    mongodb)                  mongodb ;;
    server)                   server ;;
    all)                      zones; rds mysql; rds mariadb; rds postgresql; mongodb; server ;;
esac

echo -e "${YELLOW}Copy the values into .env. An RDS class only fits the version, edition and${NC}"
echo -e "${YELLOW}storage type it is listed for - change one, then run this again.${NC}"
