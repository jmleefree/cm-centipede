terraform {
  required_version = ">= 1.6"
  required_providers {
    google = { source = "hashicorp/google", version = "~> 7.0" }
    vault  = { source = "hashicorp/vault", version = "~> 4.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

# The vault provider reads VAULT_ADDR / VAULT_TOKEN from the environment.
provider "vault" {}

# The admin password (secret/db/gcp); MySQL and PostgreSQL share it. Nothing
# sensitive is passed in as a variable: the matrix never has to hold it to run
# an apply.
data "vault_kv_secret_v2" "db" {
  mount = "secret"
  name  = "db/gcp"
}

# The CSP keys are not read here. lib/csp-env.sh puts the service account JSON
# key back together from its fields as GOOGLE_CREDENTIALS, and exports the
# project as TF_VAR_gcp_project_id, before each plan/apply/destroy. A
# vault_kv_secret_v2 data source would keep the key in the state.
#
# The Cloud SQL Admin API (sqladmin) is NOT enabled here: enable it on the
# project beforehand. google_project_service would need the Cloud Resource
# Manager API as well, just to read itself back on every plan (as in tofuenv).
provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}
