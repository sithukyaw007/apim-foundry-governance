terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.20"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  # Remote state backend.
  #
  # NOTE: in a governed tenant (e.g. MCAPS) an Azure Policy can force
  # `publicNetworkAccess = Disabled` on every storage account, which makes this container
  # unreachable from an operator workstation. `scripts/bootstrap-backend.sh` detects that and can
  # apply the sanctioned `SecurityControl=Ignore` exemption tag via --security-control-ignore.
  # If neither is possible, comment this block out to fall back to local state
  # (infra/terraform.tfstate is already covered by .gitignore), or run Terraform from the jumpbox.
  backend "azurerm" {
    resource_group_name  = "REPLACE_ME_RG"
    storage_account_name = "REPLACE_ME"
    container_name       = "tfstate"
    key                  = "ai-gateway-eus2.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  storage_use_azuread = true
  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }
    resource_group {
      prevent_deletion_if_contains_resources = false # demo/teaching env: allow destroy even if RG has untracked resources
    }
  }
}

provider "azapi" {}
