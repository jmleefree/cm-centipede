terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 5.0" }
    vault   = { source = "hashicorp/vault", version = "~> 4.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "vault" {}

data "vault_kv_secret_v2" "azure" {
  mount = "secret"
  name  = "csp/azure"
}

# Read the DB admin password from OpenBao (secret/db/azure). All three engines share it.
data "vault_kv_secret_v2" "db" {
  mount = "secret"
  name  = "db/azure"
}

# azurerm 5.x registers no resource provider by default; only the ones this
# module uses are registered here, which the service principal must be allowed to do.
provider "azurerm" {
  features {}

  client_id       = data.vault_kv_secret_v2.azure.data["AZURE_CLIENT_ID"]
  client_secret   = data.vault_kv_secret_v2.azure.data["AZURE_CLIENT_SECRET"]
  tenant_id       = data.vault_kv_secret_v2.azure.data["AZURE_TENANT_ID"]
  subscription_id = data.vault_kv_secret_v2.azure.data["AZURE_SUBSCRIPTION_ID"]

  resource_provider_registrations = "none"
  resource_providers_to_register  = ["Microsoft.DBforMySQL", "Microsoft.DBforPostgreSQL", "Microsoft.DocumentDB"]
}
