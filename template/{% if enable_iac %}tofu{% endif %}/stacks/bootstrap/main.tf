# =============================================================================
# Bootstrap — Resource Group + Storage Account for OpenTofu state
# Run once per environment: just tofu-bootstrap ENV=dev
# =============================================================================

resource "azurerm_resource_group" "tfstate" {
  name     = "rg-${var.project}-tfstate-${var.environment}"
  location = var.location

  tags = {
    environment = var.environment
    project     = var.project
    managed_by  = "opentofu"
  }
}

resource "azurerm_storage_account" "tfstate" {
  name                     = "st${var.project}tfstate${var.environment}"
  resource_group_name      = azurerm_resource_group.tfstate.name
  location                 = azurerm_resource_group.tfstate.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  blob_properties {
    versioning_enabled = true
  }

  tags = azurerm_resource_group.tfstate.tags
}

resource "azurerm_storage_container" "tfstate" {
  name               = "tfstate"
  storage_account_id = azurerm_storage_account.tfstate.id
}
