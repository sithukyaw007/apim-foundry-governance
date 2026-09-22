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

  # Remote state backend (PARTIAL configuration - no values committed).
  #
  # The settings live in infra/backend.hcl, which is gitignored, so a real storage account name
  # never lands in version control:
  #
  #   terraform init -backend-config=backend.hcl
  #
  # scripts/bootstrap-backend.sh creates the backend and writes that file for you.
  #
  # NOTE: in a governed tenant (e.g. MCAPS) an Azure Policy can force
  # `publicNetworkAccess = Disabled` on every storage account, which makes the state container
  # unreachable from an operator workstation. The bootstrap script detects that and can apply the
  # sanctioned `SecurityControl=Ignore` exemption tag via --security-control-ignore. If neither is
  # possible, comment this block out to fall back to local state (infra/terraform.tfstate is
  # already covered by .gitignore), or run Terraform from inside the VNet on the jumpbox.
  backend "azurerm" {}
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
