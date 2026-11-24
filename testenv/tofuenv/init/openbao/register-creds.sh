#!/usr/bin/env bash
# ==============================================================================
# register-creds.sh — register credentials from .env into OpenBao KV v2
# ------------------------------------------------------------------------------
#   Registration paths:
#     secret/csp/aws  <- AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
#     secret/db/aws   <- AWS_DB_PASSWORD
#     secret/vm/aws   <- TF_VAR_aws_vm_server_password  (the servers installed on the aws VM)
#     secret/csp/ncp  <- NCP_ACCESS_KEY, NCP_SECRET_KEY
#     secret/db/ncp   <- NCP_DB_PASSWORD
#     secret/csp/alibaba <- ALIBABA_ACCESS_KEY_ID, ALIBABA_ACCESS_KEY_SECRET
#     secret/db/alibaba  <- ALIBABA_DB_PASSWORD  (RDS and MongoDB share it)
#     secret/csp/azure   <- AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID,
#                           AZURE_SUBSCRIPTION_ID, AZURE_S3_ACCESS_KEY, AZURE_S3_SECRET_KEY
#     secret/db/azure    <- AZURE_DB_PASSWORD  (MySQL, PostgreSQL and MongoDB share it)
#     secret/csp/gcp     <- GCP_CLIENT_ID, GCP_CLIENT_EMAIL, GCP_PRIVATE_KEY_ID,
#                           GCP_PRIVATE_KEY, GCP_PROJECT_ID, GCP_S3_ACCESS_KEY, GCP_S3_SECRET_KEY
#     secret/db/gcp      <- GCP_DB_PASSWORD  (MySQL and PostgreSQL share it)
#
#   Idempotency:
#     - A group is skipped when its "trigger" key is empty, so re-running after
#       the keys have been blanked never overwrites the stored OpenBao secrets.
#
#   Defense-in-depth:
#     - On successful registration the matching .env keys are blanked
#       (disable with --keep-env).
#
#   Usage:
#     ./register-creds.sh              # register + blank .env keys
#     ./register-creds.sh --keep-env   # register only, keep .env values
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/../../.env}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

KEEP_ENV=false
[ "${1:-}" = "--keep-env" ] && KEEP_ENV=true

if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}Error: .env not found at ${ENV_FILE}${NC}" >&2
    exit 1
fi

# Checked here as well as in up.sh: ./scripts/register-creds.sh execs straight
# into this file, so up.sh is not the only way in.
# shellcheck source=../../scripts/lib/env-perm.sh
. "$SCRIPT_DIR/../../scripts/lib/env-perm.sh"
check_env_perm "$ENV_FILE" || exit 1

# Load .env
set -a; . "$ENV_FILE"; set +a

# Before anything is registered: a ChangeMe would otherwise be stored in OpenBao
# as if it were a real key.
assert_no_placeholder || exit 1
VAULT_ADDR="${VAULT_ADDR:-http://localhost:38200}"

if [ -z "${VAULT_TOKEN:-}" ]; then
    echo -e "${RED}Error: VAULT_TOKEN is empty. Run openbao-init.sh first.${NC}" >&2
    exit 1
fi

# Check OpenBao status.
# Note: jq's // operator substitutes on false as well as null, so booleans
#       (.sealed etc.) are compared directly instead of using //.
STATUS=$(curl -sf "${VAULT_ADDR}/v1/sys/seal-status" 2>/dev/null || echo '{}')
INITIALIZED=$(echo "$STATUS" | jq -r '.initialized')
SEALED=$(echo "$STATUS" | jq -r '.sealed')
if [ "$INITIALIZED" != "true" ]; then
    echo -e "${RED}Error: OpenBao is uninitialized or unreachable (${VAULT_ADDR}). Run openbao-init.sh.${NC}" >&2; exit 1
fi
if [ "$SEALED" != "false" ]; then
    echo -e "${RED}Error: OpenBao is sealed. Run openbao-unseal.sh.${NC}" >&2; exit 1
fi

echo -e "${CYAN}=== Registering credentials into OpenBao (${VAULT_ADDR}) ===${NC}"

# Keys to blank after a successful registration
KEYS_TO_BLANK=()

# Build {data:{k:v,...}} JSON (jq escapes values safely)
build_payload() {
    local json='{}'
    local k v
    for k in "$@"; do
        v="${!k:-}"
        json=$(jq -n --argjson base "$json" --arg key "$k" --arg val "$v" '$base + {($key): $val}')
    done
    jq -n --argjson d "$json" '{data: $d}'
}

# register_group <path> <trigger_key> <key...>
register_group() {
    local path="$1" trigger="$2"; shift 2
    local keys=("$@")
    if [ -z "${!trigger:-}" ]; then
        echo -e "  ${YELLOW}SKIP${NC} secret/${path}  (${trigger} is empty -> keeping stored value)"
        return 0
    fi
    local payload; payload=$(build_payload "${keys[@]}")
    if curl -sf -X POST "${VAULT_ADDR}/v1/secret/data/${path}" \
            -H "X-Vault-Token: ${VAULT_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$payload" >/dev/null; then
        echo -e "  ${GREEN}OK${NC}   secret/${path}  registered (${#keys[@]} keys)"
        KEYS_TO_BLANK+=("${keys[@]}")
    else
        echo -e "  ${RED}FAIL${NC} secret/${path}  registration failed"
        return 1
    fi
}

# Validate the NCP managed-DB password against the same rules the ncloud
# provider enforces: 8-20 chars, at least one letter / digit / special char,
# and none of ` & + \ " ' / or whitespace.
# Without this pre-check the failure only surfaces after a ~30 min apply.
validate_ncp_db_password() {
    local pw="$1"
    # Assign len on its own line: in `local a="$1" b=${#a}` bash expands ${#a}
    # before a is assigned, which would always yield 0.
    local len=${#pw}
    if [ "$len" -lt 8 ] || [ "$len" -gt 20 ]; then
        echo "must be 8-20 characters (currently ${len})"; return 1
    fi
    printf '%s' "$pw" | LC_ALL=C grep -q '[A-Za-z]' || { echo "must contain at least one letter"; return 1; }
    printf '%s' "$pw" | LC_ALL=C grep -q '[0-9]'    || { echo "must contain at least one digit"; return 1; }
    printf '%s' "$pw" | LC_ALL=C grep -q '[]~!@#$%^*()_={};:,.<>?[-]' \
        || { echo "must contain at least one special character from ~!@#\$%^*()-_=[]{};:,.<>?"; return 1; }
    if printf '%s' "$pw" | LC_ALL=C grep -q '[`&+\\"'"'"'/[:space:]]'; then
        echo "contains a forbidden character (\` & + \\ \" ' / or whitespace)"; return 1
    fi
    return 0
}

if [ -n "${NCP_DB_PASSWORD:-}" ]; then
    if ! reason=$(validate_ncp_db_password "$NCP_DB_PASSWORD"); then
        echo -e "  ${RED}FAIL${NC} NCP_DB_PASSWORD rejected: ${reason}" >&2
        echo -e "  ${YELLOW}See the NCP password rules in .env.example.${NC}" >&2
        exit 1
    fi
    echo -e "  ${GREEN}OK${NC}   NCP_DB_PASSWORD passed the provider rule check"
fi

# Validate the Alibaba DB password. RDS and MongoDB share it, and both APIs apply
# the same rule: 8-32 chars, at least three of uppercase / lowercase / digit /
# special, specials from ! @ # $ % ^ & * ( ) _ + - =. Of those, @ # % are refused
# here as well: gendata puts the password into the MongoDB URI unescaped, where
# they would break it. Checked before it is stored, so a bad one never reaches
# OpenBao.
validate_alibaba_db_password() {
    local pw="$1"
    local len=${#pw}
    local kinds=0
    if [ "$len" -lt 8 ] || [ "$len" -gt 32 ]; then
        echo "must be 8-32 characters (currently ${len})"; return 1
    fi
    if printf '%s' "$pw" | LC_ALL=C grep -q '[^A-Za-z0-9!$^&*()_+=-]'; then
        echo "may contain only letters, digits and ! \$ ^ & * ( ) _ + - ="; return 1
    fi
    printf '%s' "$pw" | LC_ALL=C grep -q '[A-Z]'           && kinds=$((kinds + 1))
    printf '%s' "$pw" | LC_ALL=C grep -q '[a-z]'           && kinds=$((kinds + 1))
    printf '%s' "$pw" | LC_ALL=C grep -q '[0-9]'           && kinds=$((kinds + 1))
    printf '%s' "$pw" | LC_ALL=C grep -q '[!$^&*()_+=-]'   && kinds=$((kinds + 1))
    if [ "$kinds" -lt 3 ]; then
        echo "must mix at least three of uppercase, lowercase, digits and special characters (has ${kinds})"; return 1
    fi
    return 0
}

if [ -n "${ALIBABA_DB_PASSWORD:-}" ]; then
    if ! reason=$(validate_alibaba_db_password "$ALIBABA_DB_PASSWORD"); then
        echo -e "  ${RED}FAIL${NC} ALIBABA_DB_PASSWORD rejected: ${reason}" >&2
        echo -e "  ${YELLOW}See the Alibaba password rules in .env.example.${NC}" >&2
        exit 1
    fi
    echo -e "  ${GREEN}OK${NC}   ALIBABA_DB_PASSWORD passed the RDS + MongoDB rule check"
fi

# Validate the Azure DB password. MySQL and PostgreSQL Flexible Server and MongoDB
# vCore share it: 8-128 chars, at least three of uppercase / lowercase / digit /
# special, and it must not contain the admin login (Azure refuses that). As for
# Alibaba, only ! $ ^ & * ( ) _ + - = are accepted as specials: @ # % and the like
# would break the connection URIs the password ends up in.
validate_azure_db_password() {
    local pw="$1" user="$2"
    local len=${#pw}
    local kinds=0
    if [ "$len" -lt 8 ] || [ "$len" -gt 128 ]; then
        echo "must be 8-128 characters (currently ${len})"; return 1
    fi
    if printf '%s' "$pw" | LC_ALL=C grep -q '[^A-Za-z0-9!$^&*()_+=-]'; then
        echo "may contain only letters, digits and ! \$ ^ & * ( ) _ + - ="; return 1
    fi
    printf '%s' "$pw" | LC_ALL=C grep -q '[A-Z]'           && kinds=$((kinds + 1))
    printf '%s' "$pw" | LC_ALL=C grep -q '[a-z]'           && kinds=$((kinds + 1))
    printf '%s' "$pw" | LC_ALL=C grep -q '[0-9]'           && kinds=$((kinds + 1))
    printf '%s' "$pw" | LC_ALL=C grep -q '[!$^&*()_+=-]'   && kinds=$((kinds + 1))
    if [ "$kinds" -lt 3 ]; then
        echo "must mix at least three of uppercase, lowercase, digits and special characters (has ${kinds})"; return 1
    fi
    if [ -n "$user" ] && printf '%s' "$pw" | LC_ALL=C grep -qiF -- "$user"; then
        echo "must not contain the admin login '${user}' (TF_VAR_azure_db_username)"; return 1
    fi
    return 0
}

if [ -n "${AZURE_DB_PASSWORD:-}" ]; then
    if ! reason=$(validate_azure_db_password "$AZURE_DB_PASSWORD" "${TF_VAR_azure_db_username:-dbadmin}"); then
        echo -e "  ${RED}FAIL${NC} AZURE_DB_PASSWORD rejected: ${reason}" >&2
        echo -e "  ${YELLOW}See the Azure password rules in .env.example.${NC}" >&2
        exit 1
    fi
    echo -e "  ${GREEN}OK${NC}   AZURE_DB_PASSWORD passed the MySQL + PostgreSQL + MongoDB rule check"
fi

# secret/csp/azure holds six keys, and a registration replaces the whole secret.
# Registering with some of them empty would store those empty over the ones
# already there - the S3 keys lost because only the service principal was filled
# in, say. So once any of the six is set, all six must be.
AZURE_CSP_KEYS="AZURE_CLIENT_ID AZURE_CLIENT_SECRET AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID AZURE_S3_ACCESS_KEY AZURE_S3_SECRET_KEY"
azure_set="" azure_missing=""
for k in $AZURE_CSP_KEYS; do
    if [ -n "${!k:-}" ]; then azure_set="$azure_set $k"; else azure_missing="$azure_missing $k"; fi
done
if [ -n "$azure_set" ] && [ -n "$azure_missing" ]; then
    echo -e "  ${RED}FAIL${NC} secret/csp/azure needs all six keys at once; these are empty:${azure_missing}" >&2
    echo -e "  ${YELLOW}It is stored as one secret, so a partial registration would blank the others.${NC}" >&2
    exit 1
fi

# Validate the GCP DB password. Cloud SQL for MySQL and PostgreSQL share it. Cloud
# SQL sets no rule of its own unless a password policy is configured, so this is
# the Azure rule with a 64-character cap: at least three of uppercase / lowercase /
# digit / special, specials only from ! $ ^ & * ( ) _ + - = so the connection URIs
# hold it unescaped.
validate_gcp_db_password() {
    local pw="$1"
    local len=${#pw}
    local kinds=0
    if [ "$len" -lt 8 ] || [ "$len" -gt 64 ]; then
        echo "must be 8-64 characters (currently ${len})"; return 1
    fi
    if printf '%s' "$pw" | LC_ALL=C grep -q '[^A-Za-z0-9!$^&*()_+=-]'; then
        echo "may contain only letters, digits and ! \$ ^ & * ( ) _ + - ="; return 1
    fi
    printf '%s' "$pw" | LC_ALL=C grep -q '[A-Z]'           && kinds=$((kinds + 1))
    printf '%s' "$pw" | LC_ALL=C grep -q '[a-z]'           && kinds=$((kinds + 1))
    printf '%s' "$pw" | LC_ALL=C grep -q '[0-9]'           && kinds=$((kinds + 1))
    printf '%s' "$pw" | LC_ALL=C grep -q '[!$^&*()_+=-]'   && kinds=$((kinds + 1))
    if [ "$kinds" -lt 3 ]; then
        echo "must mix at least three of uppercase, lowercase, digits and special characters (has ${kinds})"; return 1
    fi
    return 0
}

if [ -n "${GCP_DB_PASSWORD:-}" ]; then
    if ! reason=$(validate_gcp_db_password "$GCP_DB_PASSWORD"); then
        echo -e "  ${RED}FAIL${NC} GCP_DB_PASSWORD rejected: ${reason}" >&2
        echo -e "  ${YELLOW}See the GCP password rules in .env.example.${NC}" >&2
        exit 1
    fi
    echo -e "  ${GREEN}OK${NC}   GCP_DB_PASSWORD passed the MySQL + PostgreSQL rule check"
fi

# secret/csp/gcp holds seven keys and is replaced as a whole, as for Azure: once
# any of them is set, all seven must be.
GCP_CSP_KEYS="GCP_CLIENT_ID GCP_CLIENT_EMAIL GCP_PRIVATE_KEY_ID GCP_PRIVATE_KEY GCP_PROJECT_ID GCP_S3_ACCESS_KEY GCP_S3_SECRET_KEY"
gcp_set="" gcp_missing=""
for k in $GCP_CSP_KEYS; do
    if [ -n "${!k:-}" ]; then gcp_set="$gcp_set $k"; else gcp_missing="$gcp_missing $k"; fi
done
if [ -n "$gcp_set" ] && [ -n "$gcp_missing" ]; then
    echo -e "  ${RED}FAIL${NC} secret/csp/gcp needs all seven keys at once; these are empty:${gcp_missing}" >&2
    echo -e "  ${YELLOW}It is stored as one secret, so a partial registration would blank the others.${NC}" >&2
    exit 1
fi

# Check the service account fields have the shape of a JSON key's, so a value
# pasted into the wrong key - or a private key with real newlines - is caught here
# rather than as an authentication error at the first apply. GCP_PRIVATE_KEY is
# kept as .env holds it, one line with literal \n (cb-tumblebug's format); the
# modules turn those into newlines.
validate_gcp_service_account() {
    local pk="$GCP_PRIVATE_KEY"
    printf '%s' "$GCP_CLIENT_ID" | LC_ALL=C grep -qx '[0-9]\{10,30\}' \
        || { echo "GCP_CLIENT_ID must be the numeric client_id (unique ID) of the service account"; return 1; }
    printf '%s' "$GCP_CLIENT_EMAIL" | LC_ALL=C grep -qx '[^@[:space:]]\{1,\}@[^@[:space:]]\{1,\}' \
        || { echo "GCP_CLIENT_EMAIL must be the client_email of the service account (name@project.iam.gserviceaccount.com)"; return 1; }
    printf '%s' "$GCP_PRIVATE_KEY_ID" | LC_ALL=C grep -qx '[0-9a-f]\{40\}' \
        || { echo "GCP_PRIVATE_KEY_ID must be the 40-character hex private_key_id of the key"; return 1; }
    printf '%s' "$GCP_PROJECT_ID" | LC_ALL=C grep -qx '[a-z][a-z0-9-]\{4,28\}[a-z0-9]' \
        || { echo "GCP_PROJECT_ID must be the project ID (6-30 lowercase letters, digits, hyphens), not the project name or number"; return 1; }
    case "$pk" in
        '-----BEGIN PRIVATE KEY-----\n'*'\n-----END PRIVATE KEY-----'*) ;;
        *)
            echo "GCP_PRIVATE_KEY must be the private_key of the JSON key on one line, '-----BEGIN PRIVATE KEY-----\\n...\\n-----END PRIVATE KEY-----\\n'"; return 1 ;;
    esac
    return 0
}

if [ -n "$gcp_set" ]; then
    if ! reason=$(validate_gcp_service_account); then
        echo -e "  ${RED}FAIL${NC} secret/csp/gcp rejected: ${reason}" >&2
        echo -e "  ${YELLOW}See the GCP service account notes in .env.example.${NC}" >&2
        exit 1
    fi
    echo -e "  ${GREEN}OK${NC}   GCP service account fields look like a JSON key's"
fi

# Validate the aws VM server password against the rules tofu/aws/vm enforces:
# 8+ characters (MinIO's minimum) and none of ' " ` \ $ or whitespace, since the
# install scripts write it into SQL, bash, PowerShell, YAML and XML unquoted.
# Checked before it is stored, so a bad one never reaches OpenBao.
validate_vm_server_password() {
    local pw="$1"
    local len=${#pw}
    if [ "$len" -lt 8 ]; then
        echo "must be at least 8 characters (currently ${len})"; return 1
    fi
    if printf '%s' "$pw" | LC_ALL=C grep -q '['"'"'"`\\$[:space:]]'; then
        echo "contains a forbidden character (' \" \` \\ \$ or whitespace)"; return 1
    fi
    return 0
}

if [ -n "${TF_VAR_aws_vm_server_password:-}" ]; then
    if ! reason=$(validate_vm_server_password "$TF_VAR_aws_vm_server_password"); then
        echo -e "  ${RED}FAIL${NC} TF_VAR_aws_vm_server_password rejected: ${reason}" >&2
        exit 1
    fi
    echo -e "  ${GREEN}OK${NC}   TF_VAR_aws_vm_server_password passed the rule check"
fi

register_group "csp/aws" "AWS_SECRET_ACCESS_KEY" \
    AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
register_group "db/aws" "AWS_DB_PASSWORD" \
    AWS_DB_PASSWORD
register_group "vm/aws" "TF_VAR_aws_vm_server_password" \
    TF_VAR_aws_vm_server_password
register_group "csp/ncp" "NCP_SECRET_KEY" \
    NCP_ACCESS_KEY NCP_SECRET_KEY
register_group "db/ncp" "NCP_DB_PASSWORD" \
    NCP_DB_PASSWORD
register_group "csp/alibaba" "ALIBABA_ACCESS_KEY_SECRET" \
    ALIBABA_ACCESS_KEY_ID ALIBABA_ACCESS_KEY_SECRET
register_group "db/alibaba" "ALIBABA_DB_PASSWORD" \
    ALIBABA_DB_PASSWORD
register_group "csp/azure" "AZURE_CLIENT_SECRET" \
    AZURE_CLIENT_ID AZURE_CLIENT_SECRET AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID \
    AZURE_S3_ACCESS_KEY AZURE_S3_SECRET_KEY
register_group "db/azure" "AZURE_DB_PASSWORD" \
    AZURE_DB_PASSWORD
register_group "csp/gcp" "GCP_PRIVATE_KEY" \
    GCP_CLIENT_ID GCP_CLIENT_EMAIL GCP_PRIVATE_KEY_ID GCP_PRIVATE_KEY GCP_PROJECT_ID \
    GCP_S3_ACCESS_KEY GCP_S3_SECRET_KEY
register_group "db/gcp" "GCP_DB_PASSWORD" \
    GCP_DB_PASSWORD

# Blank the keys that were registered successfully
if [ "${#KEYS_TO_BLANK[@]}" -gt 0 ]; then
    if $KEEP_ENV; then
        echo -e "${YELLOW}[--keep-env]${NC} Skipping .env blanking."
    else
        for k in "${KEYS_TO_BLANK[@]}"; do
            sed -i "s|^${k}=.*|${k}=|" "$ENV_FILE"
        done
        echo -e "${GREEN}[register-creds]${NC} Blanked the successfully registered credential keys in .env."
    fi
else
    echo -e "${YELLOW}[register-creds]${NC} No new credentials registered (all empty or already stored)."
fi

echo -e "${CYAN}=== Done ===${NC}"
echo "  Verify:  curl -s -H \"X-Vault-Token: \$VAULT_TOKEN\" ${VAULT_ADDR}/v1/secret/data/csp/aws | jq .data.data"
echo "           curl -s -H \"X-Vault-Token: \$VAULT_TOKEN\" ${VAULT_ADDR}/v1/secret/data/csp/ncp | jq .data.data"
echo "           curl -s -H \"X-Vault-Token: \$VAULT_TOKEN\" ${VAULT_ADDR}/v1/secret/data/csp/alibaba | jq .data.data"
echo "           curl -s -H \"X-Vault-Token: \$VAULT_TOKEN\" ${VAULT_ADDR}/v1/secret/data/csp/azure | jq .data.data"
echo "           curl -s -H \"X-Vault-Token: \$VAULT_TOKEN\" ${VAULT_ADDR}/v1/secret/data/csp/gcp | jq .data.data"
