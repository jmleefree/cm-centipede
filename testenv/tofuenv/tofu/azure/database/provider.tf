terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 5.0" }
    vault   = { source = "hashicorp/vault", version = "~> 4.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

# The vault provider reads the VAULT_ADDR / VAULT_TOKEN environment variables automatically.
provider "vault" {}

# Read the DB admin password from OpenBao (secret/db/azure). All three engines share it.
data "vault_kv_secret_v2" "db" {
  mount = "secret"
  name  = "db/azure"
}

# The service principal comes from OpenBao (secret/csp/azure) as ARM_CLIENT_ID /
# _CLIENT_SECRET / _TENANT_ID / _SUBSCRIPTION_ID, exported by scripts/lib/csp-env.sh:
# a data source would keep it in the state.

# azurerm 5.x registers no resource provider by default; only the ones this
# module uses are registered here, which the service principal must be allowed to do.
provider "azurerm" {
  features {}

  resource_provider_registrations = "none"
  resource_providers_to_register  = ["Microsoft.DBforMySQL", "Microsoft.DBforPostgreSQL", "Microsoft.DocumentDB"]
}
