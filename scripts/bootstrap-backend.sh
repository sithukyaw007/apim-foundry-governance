#!/usr/bin/env bash
# One-time bootstrap of the remote Terraform state backend.
# Run once per subscription before `terraform init`.
#
# Usage:
#   ./bootstrap-backend.sh \
#     --location eastus2 \
#     --backend-rg rg-aigw-tfstate-dev-eastus2 \
#     --storage-prefix staigwtfstate \
#     --state-key ai-gateway-eus2.tfstate
#
# Optional:
#   --security-control-ignore
#     Tag the storage account with `SecurityControl=Ignore` and re-assert public network access.
#     Some governed tenants (e.g. MCAPS) apply a policy that forces `publicNetworkAccess=Disabled`
#     on every storage account, which makes the state container unreachable from an operator
#     workstation. In those tenants this tag is the sanctioned exemption. Only use it if your
#     organization recognizes that tag.
set -euo pipefail

LOCATION="koreacentral"
BACKEND_RG="rg-llmgw-tfstate-dev-koreacentral"
STORAGE_PREFIX="stllmgwtfstate"
STATE_KEY="llm-gateway.tfstate"
SECURITY_CONTROL_IGNORE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --location)       LOCATION="$2";       shift 2 ;;
    --backend-rg)     BACKEND_RG="$2";     shift 2 ;;
    --storage-prefix) STORAGE_PREFIX="$2"; shift 2 ;;
    --state-key)      STATE_KEY="$2";      shift 2 ;;
    --security-control-ignore) SECURITY_CONTROL_IGNORE="true"; shift ;;
    -h|--help)
      # Print only the leading header comment block (stop at the first non-comment line).
      awk 'NR==1 && /^#!/ { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1 ;;
  esac
done

if (( ${#STORAGE_PREFIX} + 6 > 24 )); then
  echo "StoragePrefix must be <= 18 characters (leaves room for a 6-char suffix)." >&2
  exit 1
fi

# storage names: lowercase+digits, <=24 chars
# NOTE: do not pipe an unbounded `/dev/urandom` read into `head -c N` — `head` closes the pipe
# and kills the producer with SIGPIPE (exit 141), which `set -o pipefail` correctly treats as a
# failure. Read a bounded chunk instead and slice it with parameter expansion.
suffix="$(head -c 1024 /dev/urandom | LC_ALL=C tr -dc 'a-z0-9')"
suffix="${suffix:0:6}"
if (( ${#suffix} < 6 )); then
  echo "Failed to generate a 6-character random suffix." >&2
  exit 1
fi
account="${STORAGE_PREFIX}${suffix}"

az group create --name "$BACKEND_RG" --location "$LOCATION"

# NOTE: the Terraform state backend is OPERATOR infrastructure, not the gateway itself.
# It must be reachable from wherever you run `terraform` (e.g. a workstation outside the VNet),
# so public network access is Enabled. Anonymous/public blob access stays disabled
# (--allow-blob-public-access false), so Entra ID auth is still required to read/write state.
# Some subscription policies default storage to public-access Disabled; set it explicitly here
# to avoid a 403 "not authorized" at `terraform init`/`apply` time.
az storage account create \
  --name "$account" --resource-group "$BACKEND_RG" --location "$LOCATION" \
  --sku Standard_LRS --kind StorageV2 \
  --allow-blob-public-access false --min-tls-version TLS1_2 \
  --public-network-access Enabled

# A governed tenant may have a policy that silently forces publicNetworkAccess back to Disabled.
# Detect that explicitly rather than failing later with an opaque "blocked by network rules" error
# during container create or `terraform init`.
public_access="$(az storage account show --name "$account" --resource-group "$BACKEND_RG" \
  --query publicNetworkAccess -o tsv)"

if [[ "$public_access" != "Enabled" && "$SECURITY_CONTROL_IGNORE" == "true" ]]; then
  echo "publicNetworkAccess is '$public_access'; applying SecurityControl=Ignore and retrying."
  az storage account update --name "$account" --resource-group "$BACKEND_RG" \
    --set tags.SecurityControl=Ignore >/dev/null
  az storage account update --name "$account" --resource-group "$BACKEND_RG" \
    --public-network-access Enabled >/dev/null
  public_access="$(az storage account show --name "$account" --resource-group "$BACKEND_RG" \
    --query publicNetworkAccess -o tsv)"
fi

if [[ "$public_access" != "Enabled" ]]; then
  cat >&2 <<EOF
ERROR: storage account '$account' has publicNetworkAccess='$public_access'.
A tenant policy is forcing private-only storage, so the Terraform state container is not
reachable from this workstation. Options:
  * Re-run with --security-control-ignore (if your tenant honours the SecurityControl=Ignore tag).
  * Request a policy exemption for this resource group.
  * Run Terraform from inside the VNet (the jumpbox) and give this account a private endpoint.
  * Use local state: leave the backend "azurerm" block in infra/providers.tf commented out.
EOF
  exit 1
fi

oid=$(az ad signed-in-user show --query id -o tsv)
subId="$(az account show --query id -o tsv)"
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee "$oid" \
  --scope "/subscriptions/$subId/resourceGroups/$BACKEND_RG/providers/Microsoft.Storage/storageAccounts/$account"

# Data-plane RBAC propagation is eventually consistent; a fixed short sleep is not enough.
# Retry the container create until the role assignment is visible to the storage data plane.
for attempt in $(seq 1 20); do
  if az storage container create --name tfstate --account-name "$account" --auth-mode login >/dev/null 2>&1; then
    echo "State container ready (attempt $attempt)."
    break
  fi
  if (( attempt == 20 )); then
    echo "ERROR: could not create the 'tfstate' container after 20 attempts." >&2
    exit 1
  fi
  sleep 15
done

# Auto-update infra/providers.tf backend "azurerm" block with the values above.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_TF="$SCRIPT_DIR/../infra/providers.tf"
if [[ -f "$PROVIDERS_TF" ]] && grep -q 'backend "azurerm"' "$PROVIDERS_TF"; then
  # Portable in-place edit: GNU sed wants `-i`, BSD/macOS sed wants `-i ''`. Writing to a temp
  # file and moving it back avoids the difference entirely. `-E` must precede the script so it
  # is never mistaken for the backup suffix.
  tmp="$(mktemp)"
  sed -E \
    -e "s|^([[:space:]]*resource_group_name[[:space:]]*=[[:space:]]*).*|\1\"$BACKEND_RG\"|" \
    -e "s|^([[:space:]]*storage_account_name[[:space:]]*=[[:space:]]*).*|\1\"$account\"|" \
    -e "s|^([[:space:]]*container_name[[:space:]]*=[[:space:]]*).*|\1\"tfstate\"|" \
    -e "s|^([[:space:]]*key[[:space:]]*=[[:space:]]*).*|\1\"$STATE_KEY\"|" \
    "$PROVIDERS_TF" > "$tmp"
  mv "$tmp" "$PROVIDERS_TF"

  # Verify the rewrite actually landed; a silent no-op here would send `terraform init` at the
  # wrong (or a nonexistent) state backend.
  if ! grep -q "\"$account\"" "$PROVIDERS_TF"; then
    echo "ERROR: failed to write the backend block into $PROVIDERS_TF; update it manually." >&2
    exit 1
  fi
  echo "Updated backend block in $PROVIDERS_TF."
else
  echo "WARNING: could not find $PROVIDERS_TF with a backend \"azurerm\" block; update it manually." >&2
fi

echo "Backend ready. Values written to infra/providers.tf backend block:"
echo "  resource_group_name  = \"$BACKEND_RG\""
echo "  storage_account_name = \"$account\""
echo "  container_name       = \"tfstate\""
echo "  key                  = \"$STATE_KEY\""
