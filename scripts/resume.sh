#!/usr/bin/env bash
# Bring the AI gateway back from hibernation (the inverse of scripts/shutdown.sh).
#
# Re-creates the jumpbox + Azure Bastion and the Admin UI Container App. The jumpbox
# run-command re-seeds the Cosmos config documents (id=global, id=pricing) idempotently, so it
# is safe to run whether or not those documents still exist.
#
# The Admin UI image is restored from the value shutdown.sh recorded. If that is unavailable
# (for example the stack was hibernated by hand), it falls back to the registry from Terraform
# outputs, and finally to --admin-ui-image.
#
# Usage:
#   ./scripts/resume.sh [--dry-run] [--yes] [--admin-ui-image REF]
#
# Options:
#   --dry-run           Show the Terraform plan and exit without changing anything.
#   --yes               Skip the confirmation prompt (for automation).
#   --admin-ui-image    Explicit image reference, e.g. myacr.azurecr.io/admin-ui:latest
#
# Note: re-creating the jumpbox needs jumpbox_admin_password (min 12 chars) in
# infra/terraform.tfvars, or TF_VAR_jumpbox_admin_password in the environment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tfvars.sh
source "$SCRIPT_DIR/lib/tfvars.sh"

INFRA_DIR="$SCRIPT_DIR/../infra"
TFVARS="$INFRA_DIR/terraform.tfvars"
DRY_RUN=false
ASSUME_YES=false
ADMIN_UI_IMAGE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --yes|-y)  ASSUME_YES=true; shift ;;
    --admin-ui-image) ADMIN_UI_IMAGE="$2"; shift 2 ;;
    -h|--help)
      awk 'NR==1 && /^#!/ { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
export ASSUME_YES

if [[ ! -f "$TFVARS" ]]; then
  echo "ERROR: $TFVARS not found. Create it from infra/terraform.tfvars.example first." >&2
  exit 1
fi

cd "$INFRA_DIR"

# --- work out which Admin UI image to restore -------------------------------------------------
image_value=""
if [[ -n "$ADMIN_UI_IMAGE" ]]; then
  image_value="\"$ADMIN_UI_IMAGE\""
else
  recorded="$(get_marker "$TFVARS" admin_ui_image || true)"
  if [[ -n "$recorded" && "$recorded" != '""' ]]; then
    image_value="$recorded"
  else
    registry="$(terraform output -raw registry_login_server 2>/dev/null || true)"
    if [[ -n "$registry" ]]; then
      image_value="\"$registry/admin-ui:latest\""
      echo "No recorded image; defaulting to $image_value"
    fi
  fi
fi

if [[ -z "$image_value" ]]; then
  echo "ERROR: could not determine the Admin UI image. Pass --admin-ui-image REF." >&2
  exit 1
fi

# --- the jumpbox variable validation requires a password when enable_jumpbox = true ------------
pw="$(get_tfvar "$TFVARS" jumpbox_admin_password || true)"
if [[ -z "$pw" || "$pw" == '""' ]] && [[ -z "${TF_VAR_jumpbox_admin_password:-}" ]]; then
  cat >&2 <<'EOF'
ERROR: enable_jumpbox = true requires jumpbox_admin_password (min 12 characters).
Set it in infra/terraform.tfvars, or export TF_VAR_jumpbox_admin_password, then re-run.
EOF
  exit 1
fi

set_tfvar "$TFVARS" enable_jumpbox true
set_tfvar "$TFVARS" admin_ui_image "$image_value"

echo
echo "Planned changes: re-create jumpbox + Bastion and the Admin UI ($image_value)."
echo "The jumpbox run-command re-seeds the Cosmos config + pricing documents idempotently."
echo

terraform plan -input=false -out=tfplan.resume

if [[ "$DRY_RUN" == "true" ]]; then
  rm -f tfplan.resume
  echo
  echo "Dry run only - no changes applied. infra/terraform.tfvars WAS updated."
  exit 0
fi

echo
if ! confirm "Apply this plan and resume the gateway?"; then
  rm -f tfplan.resume
  echo "Aborted. infra/terraform.tfvars was already updated; run ./scripts/shutdown.sh to revert."
  exit 1
fi

terraform apply -input=false -auto-approve tfplan.resume
rm -f tfplan.resume

echo
echo "Resumed."
fqdn="$(terraform output -raw admin_ui_fqdn 2>/dev/null || true)"
if [[ -n "$fqdn" ]]; then
  echo "Admin UI: https://$fqdn"
  echo "If sign-in fails with a redirect-URI error, re-point the SPA app registration at that host"
  echo "(see the 'Use it' section of the README)."
fi
terraform output -raw apim_gateway_url 2>/dev/null && echo
