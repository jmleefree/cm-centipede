#!/usr/bin/env bash
#
# lib/azure-catalog.sh — what Azure sells in one region, as one JSON object
#
#   Run INSIDE the tofu runner by lib/tofu.sh (_versions_json), from
#   /work/tofu/azure/rdbms, with AZ_REGION set:
#
#     AZ_REGION=koreacentral bash /work/scripts/lib/azure-catalog.sh
#
#   azurerm has no data source for Flexible Server versions or SKUs, so the ARM
#   REST API is called directly and read-only (GET), as tofuenv's
#   azure-db-versions.sh does: a token is requested for the service principal
#   csp-env.sh exports, then
#     Microsoft.DBforMySQL      locations/<region>/capabilities
#     Microsoft.DBforPostgreSQL locations/<region>/capabilities
#     Microsoft.DocumentDB      provider (the regions mongoClusters is sold in)
#   Nothing is created. The token never leaves the runner.
#
#   Output, in the shape _versions_json caches (tofu output -json's shape):
#     suggested_versions  {mysql: [...], postgresql: [...], mongodb: [...]}
#     azure_mysql_skus    {"8.0.21": ["B_Standard_B2s", ...], ...}
#     azure_pg_skus       ["GP_Standard_D2ds_v5", ...]
#     azure_mongodb_sold  true | false
#     azure_error         "" or why the lookup failed
#
#   Two lists come from azurerm rather than Azure, since tofu refuses anything
#   else at plan time whatever Azure sells:
#     MySQL    5.7, 8.0.21, 8.4 (azurerm 5.x validates version) - intersected
#              with what the region sells
#     MongoDB  5.0, 6.0, 7.0, 8.0 (azurerm 5.15.0, mongo_cluster r_schema.go).
#              Azure has no API listing the MongoDB vCore versions it sells, so
#              these are what tofu lets through, not a promise from the region.

set -uo pipefail

AZURERM_MYSQL_VERSIONS='["5.7","8.0.21","8.4"]'
AZURERM_MONGODB_VERSIONS='["5.0","6.0","7.0","8.0"]'

fail_json() { jq -nc --arg e "$1" '{azure_error: {value: $e}}'; exit 0; }

. /work/scripts/lib/csp-env.sh || fail_json "cannot read secret/csp/azure from OpenBao (./scripts/up.sh)"
[ -n "${AZ_REGION:-}" ] || fail_json "AZURE_REGION is empty"

reply="$(curl -s --max-time 30 -X POST "https://login.microsoftonline.com/${ARM_TENANT_ID}/oauth2/v2.0/token" \
	--data-urlencode grant_type=client_credentials \
	--data-urlencode "client_id=${ARM_CLIENT_ID}" \
	--data-urlencode "client_secret=${ARM_CLIENT_SECRET}" \
	--data-urlencode scope=https://management.azure.com/.default)"
TOK="$(jq -r '.access_token // empty' <<<"$reply" 2>/dev/null)"
[ -n "$TOK" ] || fail_json "Azure refused the token request for the service principal: $(jq -r '.error_description // .' <<<"$reply" 2>/dev/null | head -1)"

D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT

# get FILE PATH — one GET; an error leaves the reason in $D/FILE.err.
get() {
	curl -s --max-time 60 -w '%{http_code}' -o "$D/$1" -H "Authorization: Bearer $TOK" \
		"https://management.azure.com/subscriptions/${ARM_SUBSCRIPTION_ID}$2" > "$D/$1.code"
	[ "$(cat "$D/$1.code")" = "200" ] || { printf 'HTTP %s %s' "$(cat "$D/$1.code")" "$(head -c 300 "$D/$1")" > "$D/$1.err"; echo '{}' > "$D/$1"; }
}
get mysql.json "/providers/Microsoft.DBforMySQL/locations/${AZ_REGION}/capabilities?api-version=2023-12-30"
get pg.json    "/providers/Microsoft.DBforPostgreSQL/locations/${AZ_REGION}/capabilities?api-version=2024-08-01"
get docdb.json "/providers/Microsoft.DocumentDB?api-version=2021-04-01"

errors=""
for f in mysql pg docdb; do
	[ -f "$D/$f.json.err" ] && errors="${errors:+$errors; }$f: $(cat "$D/$f.json.err")"
done

# azurerm spells a Flexible Server SKU as <tier prefix>_<name>.
jq -n --slurpfile m "$D/mysql.json" --slurpfile p "$D/pg.json" --slurpfile d "$D/docdb.json" \
	--arg L "$AZ_REGION" --arg err "$errors" \
	--argjson azmy "$AZURERM_MYSQL_VERSIONS" --argjson azmg "$AZURERM_MONGODB_VERSIONS" '
	$m[0] as $mysql | $p[0] as $pg | $d[0] as $docdb |
	def pfx: {Burstable: "B_", GeneralPurpose: "GP_", MemoryOptimized: "MO_"}[.] // "";
	def norm: ascii_downcase | gsub(" "; "");
	([ $mysql.value[]? | select(.zone == "none")
	   | .supportedFlexibleServerEditions[]? | (.name) as $ed
	   | .supportedServerVersions[]? | (.name) as $v
	   | .supportedSkus[]? | {v: $v, sku: (($ed | pfx) + .name)} ]
	 | group_by(.v) | map({key: .[0].v, value: (map(.sku) | unique)}) | from_entries) as $mysql_skus |
	{
	  suggested_versions: {value: {
	    mysql:      [ $mysql_skus | keys[] | select(. as $v | $azmy | index($v)) ],
	    postgresql: [ $pg.value[0].supportedServerVersions[]?.name ] | unique,
	    mongodb:    (if ([ $docdb.resourceTypes[]? | select(.resourceType == "mongoClusters")
	                       | .locations[] | norm ] | index($L | norm)) != null
	                 then $azmg else [] end)
	  }},
	  azure_mysql_skus: {value: $mysql_skus},
	  azure_pg_skus: {value: ([ $pg.value[0].supportedServerEditions[]? | (.name) as $ed
	                            | .supportedServerSkus[]? | (($ed | pfx) + .name) ] | unique)},
	  azure_pg_restricted: {value: ($pg.value[0].restricted // "unknown")},
	  azure_mongodb_sold: {value: ([ $docdb.resourceTypes[]? | select(.resourceType == "mongoClusters")
	                                 | .locations[] | norm ] | index($L | norm) != null)},
	  azure_error: {value: $err}
	}'
