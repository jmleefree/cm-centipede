# OpenBao server configuration for cm-honeybee's dedicated secrets backend.
#
# Stores SSH access info and CSP credentials for cm-honeybee (KV v2 engine at
# secret/). TLS is disabled for local/dev; enable it (and a KMS auto-unseal
# stanza) for production.
#
# Source: https://github.com/cloud-barista/cm-honeybee/blob/main/server/openbao/openbao-config.hcl
# Reference: https://openbao.org/docs/configuration/

# Persistent storage — data survives container restarts.
storage "file" {
  path = "/openbao/data"
}

# TCP listener (TLS disabled for local development).
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

api_addr = "http://0.0.0.0:8200"

# Disable mlock for container compatibility (IPC_LOCK cap handles memory locking).
disable_mlock = true

# Web UI at http://<host>:8200/ui
ui = true

# ─────────────────────────────────────────────────────────────────────
# (Production) Cloud KMS Auto-Unseal — prefer this over the plaintext-key
# auto-unseal watcher (openbao-init) for production. Example (AWS KMS):
#
# seal "awskms" {
#   region     = "ap-northeast-2"
#   kms_key_id = "alias/openbao-honeybee-unseal"
# }
# ─────────────────────────────────────────────────────────────────────
