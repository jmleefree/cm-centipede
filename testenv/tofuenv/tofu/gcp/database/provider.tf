terraform {
  required_version = ">= 1.6"
  required_providers {
    google = { source = "hashicorp/google", version = "~> 7.0" }
    vault  = { source = "hashicorp/vault", version = "~> 4.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

# The vault provider reads the VAULT_ADDR / VAULT_TOKEN environment variables automatically.
provider "vault" {}

# Read the DB admin password from OpenBao (secret/db/gcp). Both engines share it.
data "vault_kv_secret_v2" "db" {
  mount = "secret"
  name  = "db/gcp"
}

# The service account JSON key comes from OpenBao (secret/csp/gcp) as GOOGLE_CREDENTIALS,
# put back together from its fields by scripts/lib/csp-env.sh, which also sets
# TF_VAR_gcp_project_id: a data source would keep the key in the state.

# The APIs the modules use (storage, compute, sqladmin) are NOT enabled here:
# enable them on the project beforehand. google_project_service would need the
# Cloud Resource Manager API as well, just to read itself back on every plan.
provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}
