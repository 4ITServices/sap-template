terraform {
  required_version = ">= 1.6"

  # Bootstrap uses local state — it creates the remote backend for other stacks
  backend "local" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}
