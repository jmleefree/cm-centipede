#!/usr/bin/env bash
#
# lib/csp-env.sh — hand a module's providers the CSP credentials from OpenBao
#
#   Sourced INSIDE the tofu runner, after cd into the module and before a tofu
#   command that configures providers (plan / apply / destroy / refresh-only).
#   _in_runner in lib/tofu.sh does that for every such call:
#
#     cd /work/tofu/<module>
#     . /work/scripts/lib/csp-env.sh
#     tofu apply ...
#
#   It reads secret/csp/<csp> (registered by register-creds.sh) and exports it
#   as the provider's own environment variables. The CSP follows from the
#   module directory, or from CSP_ENV=<csp> when set:
#
#     aws/*            aws
#     ncp/*, ncp-target  ncp
#     alibaba/*, alibaba-target  alibaba
#     my-target, pg-target  none - they speak the database protocol, and get
#                      their connection through variables
#
#   It takes no arguments: `.` without any hands a sourced file the caller's own
#   positional parameters, which would be read as a CSP inside a function.
#
# Why not a vault_kv_secret_v2 data source
#   The modules used to read these keys with one, and tofu keeps everything a
#   data source reads in the state. An environment variable reaches the provider
#   without passing through the state at all. The DB master password is still
#   read that way (data "vault_kv_secret_v2" "db" in the rdbms modules): the
#   instance resource stores it in state regardless, which is why the state is
#   encrypted (TF_ENCRYPTION in docker-compose.yaml).
#
#   Needs VAULT_ADDR and VAULT_TOKEN, which _in_runner exports.

_csp_env() {
	local csp="${CSP_ENV:-}" json
	if [ -z "$csp" ]; then
		case "$PWD" in
		/work/tofu/aws/*)                      csp=aws ;;
		/work/tofu/ncp/*|/work/tofu/ncp-target) csp=ncp ;;
		/work/tofu/alibaba/*|/work/tofu/alibaba-target) csp=alibaba ;;
		/work/tofu/my-target|/work/tofu/pg-target) return 0 ;;
		*) echo "csp-env.sh: no CSP is known for $PWD" >&2; return 1 ;;
		esac
	fi

	if ! json="$(curl -sf --max-time 10 -H "X-Vault-Token: ${VAULT_TOKEN:-}" \
			"${VAULT_ADDR%/}/v1/secret/data/csp/${csp}" | jq -ce '.data.data')"; then
		echo "csp-env.sh: cannot read secret/csp/${csp} from OpenBao at ${VAULT_ADDR:-<VAULT_ADDR unset>}." >&2
		echo "  Is OpenBao running and unsealed, is VAULT_TOKEN in .env current, and are" >&2
		echo "  the ${csp} credentials registered? (./scripts/up.sh)" >&2
		return 1
	fi
	_csp_get() { jq -r --arg k "$1" '.[$k] // empty' <<<"$json"; }

	case "$csp" in
	aws)
		export AWS_ACCESS_KEY_ID="$(_csp_get AWS_ACCESS_KEY_ID)"
		export AWS_SECRET_ACCESS_KEY="$(_csp_get AWS_SECRET_ACCESS_KEY)"
		;;
	ncp)
		export NCLOUD_ACCESS_KEY="$(_csp_get NCP_ACCESS_KEY)"
		export NCLOUD_SECRET_KEY="$(_csp_get NCP_SECRET_KEY)"
		;;
	alibaba)
		# alicloud 2.x and the aliyun CLI read ALIBABA_CLOUD_*; ALICLOUD_* is the
		# provider's older name for the same pair.
		export ALIBABA_CLOUD_ACCESS_KEY_ID="$(_csp_get ALIBABA_ACCESS_KEY_ID)"
		export ALIBABA_CLOUD_ACCESS_KEY_SECRET="$(_csp_get ALIBABA_ACCESS_KEY_SECRET)"
		export ALICLOUD_ACCESS_KEY="$ALIBABA_CLOUD_ACCESS_KEY_ID"
		export ALICLOUD_SECRET_KEY="$ALIBABA_CLOUD_ACCESS_KEY_SECRET"
		;;
	*)
		echo "csp-env.sh: unknown CSP '${csp}'" >&2
		unset -f _csp_get
		return 1
		;;
	esac
	unset -f _csp_get
}

_csp_env
