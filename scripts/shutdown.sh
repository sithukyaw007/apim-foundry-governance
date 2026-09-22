#!/usr/bin/env bash
# Hibernate the AI gateway to cut idle cost, without destroying it.
#
# Removes the two things that cost the most while idle and are not needed to serve traffic:
#   * the jumpbox + Azure Bastion (Bastion is billed hourly and has no stop/start), and
#   * the Admin UI Container App.
#
# Everything on the request path is left running: APIM, both model backends, Cosmos and its
# seeded documents (id=global, id=pricing), the config-sync job, and observability. The model
# deployments are GlobalStandard (PAYG), so they cost nothing while idle.
#
# The jumpbox only exists to seed Cosmos from inside the VNet. Once that is done it is dead
# weight, and `scripts/resume.sh` re-creates it and re-seeds idempotently.
#
# This edits infra/terraform.tfvars rather than passing -var overrides, so the declared desired
# state matches reality. Otherwise a later bare `terraform apply` would silently resurrect the
# expensive resources.
#
# Usage:
#   ./scripts/shutdown.sh [--dry-run] [--yes]
#
# Options:
#   --dry-run  Show the Terraform plan and exit without changing anything.
#   --yes      Skip the confirmation prompt (for automation).
#
# For zero spend instead, run `terraform destroy` in infra/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tfvars.sh
source "$SCRIPT_DIR/lib/tfvars.sh"

INFRA_DIR="$SCRIPT_DIR/../infra"
TFVARS="$INFRA_DIR/terraform.tfvars"
DRY_RUN=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --yes|-y)  ASSUME_YES=true; shift ;;
    -h|--help)
      awk 'NR==1 && /^#!/ { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
export ASSUME_YES

if [[ ! -f "$TFVARS" ]]; then
  echo "ERROR: $TFVARS not found. Nothing to hibernate." >&2
  exit 1
fi

# Remember the current Admin UI image so resume.sh can put back exactly what was running,
# rather than guessing a tag.
current_image="$(get_tfvar "$TFVARS" admin_ui_image || true)"
if [[ -n "$current_image" && "$current_image" != '""' ]]; then
  set_marker "$TFVARS" admin_ui_image "$current_image"
  echo "Recorded Admin UI image for resume: $current_image"
fi

set_tfvar "$TFVARS" enable_jumpbox false
set_tfvar "$TFVARS" admin_ui_image '""'

echo
echo "Planned changes: remove jumpbox + Bastion and the Admin UI Container App."
echo "Kept running: APIM, model backends, Cosmos (+ seeded config), config-sync job, observability."
echo

cd "$INFRA_DIR"
terraform plan -input=false -out=tfplan.shutdown

if [[ "$DRY_RUN" == "true" ]]; then
  rm -f tfplan.shutdown
  echo
  echo "Dry run only - no changes applied. infra/terraform.tfvars WAS updated; revert it or run"
  echo "./scripts/resume.sh to restore."
  exit 0
fi

echo
if ! confirm "Apply this plan and hibernate the gateway?"; then
  rm -f tfplan.shutdown
  echo "Aborted. Note that infra/terraform.tfvars was already updated; run ./scripts/resume.sh to restore."
  exit 1
fi

terraform apply -input=false -auto-approve tfplan.shutdown
rm -f tfplan.shutdown

echo
echo "Hibernated. The gateway still serves traffic:"
terraform output -raw apim_gateway_url 2>/dev/null && echo
echo "Resume with ./scripts/resume.sh - the jumpbox run-command re-seeds Cosmos idempotently."
