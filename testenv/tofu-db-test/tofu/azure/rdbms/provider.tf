terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 5.0" }
    vault   = { source = "hashicorp/vault", version = "~> 4.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

# The vault provider reads VAULT_ADDR / VAULT_TOKEN from the environment.
provider "vault" {}

# The admin password (secret/db/azure); MySQL, PostgreSQL and MongoDB share it.
# Nothing sensitive is passed in as a variable: the matrix never has to hold it
# to run an apply.
data "vault_kv_secret_v2" "db" {
  mount = "secret"
  name  = "db/azure"
}

# The CSP keys are not read here. lib/csp-env.sh exports the service principal
# as ARM_CLIENT_ID / ARM_CLIENT_SECRET / ARM_TENANT_ID / ARM_SUBSCRIPTION_ID
# before each plan/apply/destroy, which the provider reads itself. A
# vault_kv_secret_v2 data source would keep them in the state.
#
# azurerm 5.x registers no resource provider by default; only the ones this
# module uses are registered here, which the service principal must be allowed
# to do (as in tofuenv).
provider "azurerm" {
  features {}

  resource_provider_registrations = "none"
  resource_providers_to_register  = ["Microsoft.DBforMySQL", "Microsoft.DBforPostgreSQL", "Microsoft.DocumentDB"]
}
