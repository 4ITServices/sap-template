# =============================================================================
# Networking — VNet, Subnets, NSGs
# Usage: just tofu-plan STACK=networking ENV=dev
# =============================================================================

# TODO: Define your networking resources here
# Example:
# resource "azurerm_resource_group" "networking" {
#   name     = "rg-${var.project}-network-${var.environment}"
#   location = var.location
# }
#
# resource "azurerm_virtual_network" "main" {
#   name                = "vnet-${var.project}-${var.environment}"
#   resource_group_name = azurerm_resource_group.networking.name
#   location            = azurerm_resource_group.networking.location
#   address_space       = ["10.0.0.0/16"]
# }
