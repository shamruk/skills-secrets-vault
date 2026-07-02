#!/usr/bin/env bash
# Delete one stage of a service from the vault. Destructive and unrecoverable — requires
# typing 'delete <service>/<stage>' at the TTY, or --yes for scripted use.
#
# Usage: vault-delete.sh <stage> [--service <namespace>] [--yes]

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/kc-lib.sh"

STAGE=""; SVC=""; YES=0
while [[ $# -gt 0 ]]; do case "$1" in
  --service) SVC="$2"; shift 2 ;;
  --yes) YES=1; shift ;;
  -*) echo "unknown flag: $1" >&2; exit 2 ;;
  *) STAGE="$1"; shift ;;
esac; done
case "$STAGE" in production|sandbox|common) ;; *)
  echo "usage: $0 <production|sandbox|common> [--service X] [--yes]" >&2; exit 2 ;;
esac
SERVICE="$(pick_service "$SVC")"
[[ -n "$SERVICE" ]] || { echo "no service: pass --service, set SECRETS_VAULT_SERVICE, or run inside a project" >&2; exit 2; }
vault_require_age

vault_exists "$SERVICE" "$STAGE" || { echo "nothing to delete: $SERVICE/$STAGE is not in the vault"; exit 0; }
nkeys="$(de_count "$(vault_get "$SERVICE" "$STAGE")")"

{
  echo "════════════════════════════════════════════════════════════════════════"
  echo "⚠️  DELETE $SERVICE/$STAGE — $nkeys key(s) will be destroyed, unrecoverably."
  echo "════════════════════════════════════════════════════════════════════════"
} >&2
if [[ "$YES" != 1 ]]; then
  ans=""
  { read -r -p "Type 'delete $SERVICE/$STAGE' to confirm: " ans </dev/tty; } 2>/dev/null \
    || { echo "aborted: not a TTY and no --yes — refusing to delete" >&2; exit 1; }
  [[ "$ans" == "delete $SERVICE/$STAGE" ]] || { echo "aborted" >&2; exit 1; }
fi

vault_delete_stage "$SERVICE" "$STAGE"
echo "deleted $SERVICE/$STAGE"
