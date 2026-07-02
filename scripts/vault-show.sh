#!/usr/bin/env bash
# Print a vault stage's contents (debug). Output contains SECRETS unless --mask is given.
#
# Usage:
#   vault-show.sh <stage> [--service <namespace>] [--mask] [KEY ...]
#   vault-show.sh sandbox --mask
#   vault-show.sh production --service lunai.care STRIPE_SECRET_KEY

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/kc-lib.sh"

STAGE=""; SVC=""; MASK=0; keys=()
while [[ $# -gt 0 ]]; do case "$1" in
  --service) SVC="$2"; shift 2 ;;
  --mask)    MASK=1; shift ;;
  -*)        echo "unknown flag: $1" >&2; exit 2 ;;
  *) if [[ -z "$STAGE" ]]; then STAGE="$1"; else keys+=("$1"); fi; shift ;;
esac; done
[[ -n "$STAGE" ]] || { echo "usage: $0 <production|sandbox|common> [--service X] [--mask] [KEY ...]" >&2; exit 2; }
SERVICE="$(pick_service "$SVC")"
[[ -n "$SERVICE" ]] || { echo "no service: pass --service, set SECRETS_VAULT_SERVICE, or run inside a project" >&2; exit 2; }
vault_require_age
vault_check_migration "$SERVICE"

blob="$(vault_get "$SERVICE" "$STAGE")" || { echo "vault not found: $SERVICE/$STAGE" >&2; exit 1; }

mask() { local v="$1"; [[ -z "$v" ]] && { printf '(blank)'; return; }
  if (( ${#v} <= 4 )); then printf '****'; else printf '%s…(%d)' "${v:0:2}" "${#v}"; fi; }
emit() { local k="$1" v; v="$(de_get "$blob" "$k")"
  if [[ "$MASK" == 1 ]]; then printf '%s=%s\n' "$k" "$(mask "$v")"; else printf '%s=%s\n' "$k" "$v"; fi; }

if [[ ${#keys[@]} -gt 0 ]]; then
  for k in "${keys[@]}"; do emit "$k"; done
else
  while IFS= read -r k; do [[ -n "$k" ]] && emit "$k"; done < <(de_keys "$blob")
fi
