terraform {
  required_version = ">= 1.6"
  required_providers {
    google = { source = "hashicorp/google", version = "~> 7.0" }
  }
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
