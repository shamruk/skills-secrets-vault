#!/usr/bin/env bash
# Show a service's 3 vault stages with key counts (filled vs blank). Never prints values.
# With no resolvable service, lists every service in the vault instead.
#
# Usage: vault-list.sh [--service <namespace>] [--all]
#   service resolves from: --service | $SECRETS_VAULT_SERVICE | nearest project's manifest.yaml

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/kc-lib.sh"

SVC=""; ALL=0
while [[ $# -gt 0 ]]; do case "$1" in
  --service) SVC="$2"; shift 2 ;;
  --all)     ALL=1; shift ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac; done
vault_require_age
SERVICE=""
[[ "$ALL" == 1 ]] || SERVICE="$(pick_service "$SVC" || true)"

echo "vault: $VAULT_DIR"
if _cloud_enabled; then
  if [[ -f "$VAULT_DIR/.mirror-pending" ]]; then echo "mirror: $VAULT_CLOUD_DIR (PENDING — run vault-sync.sh)"
  else echo "mirror: $VAULT_CLOUD_DIR"; fi
fi

count_row() {  # count_row <service> <stage> <label-width-fmt applied by caller>
  local blob total filled
  if blob="$(vault_get "$1" "$2" 2>/dev/null)"; then
    total="$(printf '%s\n' "$blob" | grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' || true)"
    filled="$(printf '%s\n' "$blob" | grep -cE '^[A-Za-z_][A-Za-z0-9_]*=.+' || true)"
    printf '%6s %7s %6s  %s' "$total" "$filled" "$((total-filled))" present
  else
    printf '%6s %7s %6s  %s' "-" "-" "-" MISSING
  fi
}

if [[ -z "$SERVICE" ]]; then
  # no project context: list every service in the vault
  found=0
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    found=1
    echo ""
    echo "service: $svc"
    printf '%-12s %6s %7s %6s  %s\n' STAGE KEYS FILLED BLANK STATE
    for v in "${KC_STAGES[@]}"; do
      printf '%-12s %s\n' "$v" "$(count_row "$svc" "$v")"
    done
  done < <(vault_services)
  [[ "$found" == 1 ]] || echo "(no services in the vault yet — see vault-init.sh / vault-import.sh)"
  exit 0
fi

vault_check_migration "$SERVICE"
echo "service: $SERVICE"
printf '%-12s %6s %7s %6s  %s\n' STAGE KEYS FILLED BLANK STATE
printf '%-12s %6s %7s %6s  %s\n' "------------" "----" "------" "-----" "-------"
for v in "${KC_STAGES[@]}"; do
  printf '%-12s %s\n' "$v" "$(count_row "$SERVICE" "$v")"
done
