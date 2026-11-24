terraform {
  required_version = ">= 1.6"
  required_providers {
    google = { source = "hashicorp/google", version = "~> 7.0" }
    vault  = { source = "hashicorp/vault", version = "~> 4.0" }
    tls    = { source = "hashicorp/tls", version = "~> 4.0" }
    local  = { source = "hashicorp/local", version = "~> 2.4" }
  }
}

# The vault provider reads the VAULT_ADDR / VAULT_TOKEN environment variables automatically.
provider "vault" {}

# Read the GCP credentials from OpenBao (secret/csp/gcp): the service account
# fields of its JSON key, and the HMAC key of Cloud Storage interoperability.
data "vault_kv_secret_v2" "gcp" {
  mount = "secret"
  name  = "csp/gcp"
}

# The JSON key is put back together from its fields, as the provider takes it.
# GCP_PRIVATE_KEY is stored as .env held it, one line with literal \n
# (cb-tumblebug's format); a PEM key needs them as real newlines.
locals {
  gcp        = data.vault_kv_secret_v2.gcp.data
  project_id = nonsensitive(local.gcp["GCP_PROJECT_ID"])
  credentials = jsonencode({
    type           = "service_account"
    project_id     = local.gcp["GCP_PROJECT_ID"]
    private_key_id = local.gcp["GCP_PRIVATE_KEY_ID"]
    private_key    = replace(local.gcp["GCP_PRIVATE_KEY"], "\\n", "\n")
    client_email   = local.gcp["GCP_CLIENT_EMAIL"]
    client_id      = local.gcp["GCP_CLIENT_ID"]
    token_uri      = "https://oauth2.googleapis.com/token"
  })
}

# The APIs the modules use (storage, compute, sqladmin) are NOT enabled here:
# enable them on the project beforehand. google_project_service would need the
# Cloud Resource Manager API as well, just to read itself back on every plan.
provider "google" {
  credentials = local.credentials
  project     = local.project_id
  region      = var.gcp_region
  zone        = var.gcp_zone
}
