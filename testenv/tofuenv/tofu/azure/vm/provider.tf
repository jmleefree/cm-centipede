terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 5.0" }
    tls     = { source = "hashicorp/tls", version = "~> 4.0" }
    local   = { source = "hashicorp/local", version = "~> 2.4" }
  }
}

# The service principal comes from OpenBao (secret/csp/azure) as ARM_CLIENT_ID /
# _CLIENT_SECRET / _TENANT_ID / _SUBSCRIPTION_ID, exported by scripts/lib/csp-env.sh:
# a data source would keep it in the state.

# azurerm 5.x registers no resource provider by default; only the ones this
# module uses are registered here, which the service principal must be allowed to do.
provider "azurerm" {
  features {}

  resource_provider_registrations = "none"
  resource_providers_to_register  = ["Microsoft.Compute", "Microsoft.Network"]
}
