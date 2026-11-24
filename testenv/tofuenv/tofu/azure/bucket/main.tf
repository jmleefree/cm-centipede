# ---------------------------------------------------------------------------
# Azure Blob container, used as the object storage migration test target.
#   Azure Blob has no S3 API. The storage account is NOT created here: it must
#   already exist, and is given as AZURE_S3_ACCESS_KEY (its name, the
#   cb-tumblebug / cb-spider S3AccessKey) with one of its keys as
#   AZURE_S3_SECRET_KEY. This module creates only the container in it, so a
#   teardown removes the container - with every blob in it - and leaves the
#   account and its other containers alone.
#   gendata fills the container through the azblob SDK; this module owns the
#   container lifecycle.
# ---------------------------------------------------------------------------
# The account name is not a secret - it is the host name of the Blob endpoint,
# <name>.blob.core.windows.net - so scripts/lib/csp-env.sh hands it over from
# OpenBao as a plain variable, which the outputs and the precondition message
# show. The account key (AZURE_S3_SECRET_KEY) is not read by this module at all.
locals {
  storage_account_name = var.azure_storage_account_name
}

# The account is found by name alone: its resource group is not asked for in
# .env, and an account name is unique across Azure anyway.
data "azurerm_resources" "storage_account" {
  type = "Microsoft.Storage/storageAccounts"
  name = local.storage_account_name
}

locals {
  storage_account    = try(data.azurerm_resources.storage_account.resources[0], null)
  storage_account_id = try(local.storage_account.id, null)
}

resource "azurerm_storage_container" "this" {
  name                  = var.azure_bucket_name
  storage_account_id    = local.storage_account_id
  container_access_type = "private"

  lifecycle {
    precondition {
      condition     = local.storage_account_id != null
      error_message = "No storage account named '${local.storage_account_name}' (AZURE_S3_ACCESS_KEY) is visible to the service principal in this subscription. Create it first, or check the name and the principal's role."
    }
  }
}
