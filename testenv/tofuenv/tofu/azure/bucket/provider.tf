terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 5.0" }
    vault   = { source = "hashicorp/vault", version = "~> 4.0" }
  }
}

# The vault provider reads the VAULT_ADDR / VAULT_TOKEN environment variables automatically.
provider "vault" {}

# Read the Azure credentials from OpenBao (secret/csp/azure): the service
# principal, and the S3AccessKey / S3SecretKey of the existing storage account.
data "vault_kv_secret_v2" "azure" {
  mount = "secret"
  name  = "csp/azure"
}

# azurerm 5.x registers no resource provider by default; only the one this
# module uses is registered here, which the service principal must be allowed to do.
provider "azurerm" {
  features {}

  client_id       = data.vault_kv_secret_v2.azure.data["AZURE_CLIENT_ID"]
  client_secret   = data.vault_kv_secret_v2.azure.data["AZURE_CLIENT_SECRET"]
  tenant_id       = data.vault_kv_secret_v2.azure.data["AZURE_TENANT_ID"]
  subscription_id = data.vault_kv_secret_v2.azure.data["AZURE_SUBSCRIPTION_ID"]

  resource_provider_registrations = "none"
  resource_providers_to_register  = ["Microsoft.Storage"]
}
