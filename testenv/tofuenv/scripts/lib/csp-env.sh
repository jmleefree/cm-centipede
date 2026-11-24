#!/usr/bin/env bash
# ==============================================================================
# csp-env.sh — hand a module's providers the CSP credentials from OpenBao
# ------------------------------------------------------------------------------
#   Sourced INSIDE tofu-runner, after cd into the module and before the tofu
#   command that configures providers (plan / apply / destroy / refresh-only):
#
#     cd /work/tofu/<csp>/<module>
#     . /work/scripts/lib/csp-env.sh
#     tofu apply ...
#
#   It reads secret/csp/<csp> (registered by register-creds.sh) and exports it
#   as the provider's own environment variables. The CSP is taken from the
#   current directory, or from CSP_ENV=<csp> when set. It takes no arguments:
#   `.` without any hands a sourced file the caller's own positional parameters,
#   which would be read as a CSP inside a function.
#
#   WHY NOT A vault_kv_secret_v2 DATA SOURCE
#   The modules used to read these keys with one, and tofu keeps everything a
#   data source reads in the state. An environment variable reaches the
#   provider without passing through the state at all.
#
#   Commands that only read the state (output, state, show, workspace, init,
#   validate) need none of this. Needs VAULT_ADDR and VAULT_TOKEN, which the
#   compose file sets and the callers export.
# ==============================================================================

_csp_env() {
    local csp="${CSP_ENV:-}" json
    if [ -z "$csp" ]; then
        case "$PWD" in
            /work/tofu/*/*) csp="${PWD#/work/tofu/}"; csp="${csp%%/*}" ;;
            *) echo "csp-env.sh: not in a /work/tofu/<csp>/<module> directory ($PWD)" >&2; return 1 ;;
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
            # alicloud 2.x reads ALIBABA_CLOUD_*; ALICLOUD_* is its older name.
            export ALIBABA_CLOUD_ACCESS_KEY_ID="$(_csp_get ALIBABA_ACCESS_KEY_ID)"
            export ALIBABA_CLOUD_ACCESS_KEY_SECRET="$(_csp_get ALIBABA_ACCESS_KEY_SECRET)"
            export ALICLOUD_ACCESS_KEY="$ALIBABA_CLOUD_ACCESS_KEY_ID"
            export ALICLOUD_SECRET_KEY="$ALIBABA_CLOUD_ACCESS_KEY_SECRET"
            ;;
        azure)
            export ARM_CLIENT_ID="$(_csp_get AZURE_CLIENT_ID)"
            export ARM_CLIENT_SECRET="$(_csp_get AZURE_CLIENT_SECRET)"
            export ARM_TENANT_ID="$(_csp_get AZURE_TENANT_ID)"
            export ARM_SUBSCRIPTION_ID="$(_csp_get AZURE_SUBSCRIPTION_ID)"
            # Not a secret: the name of the existing storage account (S3AccessKey),
            # which azure/bucket looks up.
            export TF_VAR_azure_storage_account_name="$(_csp_get AZURE_S3_ACCESS_KEY)"
            ;;
        gcp)
            # The JSON key is put back together from its fields, as the provider
            # takes it. GCP_PRIVATE_KEY is stored as .env held it, one line with
            # literal \n (cb-tumblebug's format); a PEM key needs real newlines.
            export GOOGLE_CREDENTIALS="$(jq -c '{
                type:           "service_account",
                project_id:     .GCP_PROJECT_ID,
                private_key_id: .GCP_PRIVATE_KEY_ID,
                private_key:    ((.GCP_PRIVATE_KEY // "") | gsub("\\\\n"; "\n")),
                client_email:   .GCP_CLIENT_EMAIL,
                client_id:      .GCP_CLIENT_ID,
                token_uri:      "https://oauth2.googleapis.com/token"
            }' <<<"$json")"
            # Not a secret: the project, which the provider and an output take.
            export TF_VAR_gcp_project_id="$(_csp_get GCP_PROJECT_ID)"
            ;;
        *)
            echo "csp-env.sh: unknown CSP '${csp}'" >&2
            return 1
            ;;
    esac
    unset -f _csp_get
}

_csp_env
