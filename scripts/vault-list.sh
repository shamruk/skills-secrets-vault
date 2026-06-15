#!/usr/bin/env bash
# Show a service's 3 vault stages with key counts (filled vs blank). Never prints values.
#
# Usage: vault-list.sh [--service <namespace>]
#   service resolves from: --service | $SECRETS_VAULT_SERVICE | nearest project's manifest.yaml

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/kc-lib.sh"

SVC=""
while [[ $# -gt 0 ]]; do case "$1" in
  --service) SVC="$2"; shift 2 ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac; done
SERVICE="$(pick_service "$SVC")"
[[ -n "$SERVICE" ]] || { echo "no service: pass --service <namespace>, set SECRETS_VAULT_SERVICE, or run inside a project" >&2; exit 2; }

echo "service: $SERVICE"
printf '%-12s %6s %7s %6s  %s\n' STAGE KEYS FILLED BLANK STATE
printf '%-12s %6s %7s %6s  %s\n' "------------" "----" "------" "-----" "-------"
for v in "${KC_STAGES[@]}"; do
  if blob="$(vault_get "$SERVICE" "$v" 2>/dev/null)"; then
    total="$(printf '%s\n' "$blob" | grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' || true)"
    filled="$(printf '%s\n' "$blob" | grep -cE '^[A-Za-z_][A-Za-z0-9_]*=.+' || true)"
    printf '%-12s %6s %7s %6s  %s\n' "$v" "$total" "$filled" "$((total-filled))" present
  else
    printf '%-12s %6s %7s %6s  %s\n' "$v" "-" "-" "-" MISSING
  fi
done
