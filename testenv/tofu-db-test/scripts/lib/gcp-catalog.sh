#!/usr/bin/env bash
#
# lib/gcp-catalog.sh — what Cloud SQL offers, as one JSON object
#
#   Run INSIDE the tofu runner by lib/tofu.sh (_versions_json), from
#   /work/tofu/gcp/rdbms, with GCP_REGION set:
#
#     GCP_REGION=asia-northeast3 bash /work/scripts/lib/gcp-catalog.sh
#
#   google has no data source for Cloud SQL versions or tiers, so the sqladmin
#   REST API is called directly and read-only (GET), as tofuenv's
#   gcp-db-versions.sh does. A token is requested for the service account
#   csp-env.sh puts together (GOOGLE_CREDENTIALS): a JWT is signed RS256 with
#   its key (openssl) and traded at oauth2.googleapis.com. Then
#     sqladmin /v1/flags                versions (every flag's appliesTo)
#     sqladmin /v1/projects/<p>/tiers   predefined tiers sold in the region
#   Nothing is created. The key and the token never leave the runner.
#
#   Output, in the shape _versions_json caches (tofu output -json's shape):
#     suggested_versions  {mysql: ["8.0", "8.0.41", "8.4", ...], postgresql: ["16", ...]}
#     gcp_tiers           ["db-f1-micro", "db-g1-small", ...]  (predefined only)
#     gcp_error           "" or why the lookup failed (SERVICE_DISABLED: ...)
#
#   The versions are the ones any Cloud SQL flag applies to, written the way
#   .env takes them (MYSQL_8_4 -> 8.4, POSTGRES_16 -> 16). db-custom-<vCPU>-<MB>
#   tiers are built to measure rather than listed, so they are not checked.

set -uo pipefail
umask 077

fail_json() { jq -nc --arg e "$1" '{gcp_error: {value: $e}}'; exit 0; }

. /work/scripts/lib/csp-env.sh || fail_json "cannot read secret/csp/gcp from OpenBao (./scripts/up.sh)"
[ -n "${GOOGLE_CREDENTIALS:-}" ] || fail_json "secret/csp/gcp holds no service account"
P="${TF_VAR_gcp_project_id:-}"
[ -n "$P" ] || fail_json "GCP_PROJECT_ID is empty in secret/csp/gcp"
R="${GCP_REGION:-}"
[ -n "$R" ] || fail_json "GCP_REGION is empty"

D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT

# A JWT for the service account, signed RS256 with its key. The key file lives
# only for the signature.
b64() { base64 -w0 | tr '+/' '-_' | tr -d '='; }
jq -r '.private_key' <<<"$GOOGLE_CREDENTIALS" > "$D/key.pem"
now="$(date +%s)"
hdr="$(jq -cn --arg kid "$(jq -r '.private_key_id' <<<"$GOOGLE_CREDENTIALS")" \
	'{alg: "RS256", typ: "JWT", kid: $kid}' | b64)"
clm="$(jq -cn --arg iss "$(jq -r '.client_email' <<<"$GOOGLE_CREDENTIALS")" --argjson iat "$now" \
	'{iss: $iss, scope: "https://www.googleapis.com/auth/cloud-platform",
	  aud: "https://oauth2.googleapis.com/token", iat: $iat, exp: ($iat + 600)}' | b64)"
sig="$(printf '%s.%s' "$hdr" "$clm" | openssl dgst -sha256 -sign "$D/key.pem" -binary 2>/dev/null | b64)"
rm -f "$D/key.pem"
[ -n "$sig" ] || fail_json "could not sign the token request with the service account key (GCP_PRIVATE_KEY)"

reply="$(curl -s --max-time 30 -X POST https://oauth2.googleapis.com/token \
	--data-urlencode grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer \
	--data-urlencode "assertion=${hdr}.${clm}.${sig}")"
TOK="$(jq -r '.access_token // empty' <<<"$reply" 2>/dev/null)"
[ -n "$TOK" ] || fail_json "Google refused the token request for the service account: $(jq -r '.error_description // .error // .' <<<"$reply" 2>/dev/null | head -1)"

# get FILE URL — one GET. The body is kept on an HTTP error too: it holds the
# reason (SERVICE_DISABLED, PERMISSION_DENIED), which is reported.
get() {
	curl -s --max-time 60 -H "Authorization: Bearer $TOK" "$2" -o "$D/$1" || printf '{}' > "$D/$1"
	[ -s "$D/$1" ] || printf '{}' > "$D/$1"
}
get flags.json "https://sqladmin.googleapis.com/v1/flags"
get tiers.json "https://sqladmin.googleapis.com/v1/projects/$P/tiers"

jq -n --slurpfile f "$D/flags.json" --slurpfile t "$D/tiers.json" --arg R "$R" '
	$f[0] as $flags | $t[0] as $tiers |
	def err: if type == "object" and .error then
	           ((.error.details // [] | map(.reason // empty) | first) // .error.status // "")
	           + ": " + (.error.message // "") else null end;
	# MYSQL_8_0_41 -> 8.0.41, POSTGRES_16 -> 16
	def num($p): select(startswith($p)) | ltrimstr($p) | gsub("_"; ".");
	([ $flags.items[]?.appliesTo[]? ] | unique) as $all |
	{
	  suggested_versions: {value: {
	    mysql:      [ $all[] | num("MYSQL_") ],
	    postgresql: [ $all[] | num("POSTGRES_") ]
	  }},
	  gcp_tiers: {value: [ $tiers.items[]? | select((.region // []) | index($R)) | .tier ] | unique},
	  gcp_error: {value: (($flags | err) // ($tiers | err) // "")}
	}'
