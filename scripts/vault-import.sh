#!/usr/bin/env bash
# Merge KEY=VALUE pairs from a dotenv file (or stdin) into a vault stage. Conflict-aware:
# an existing key with a different value is reported and skipped unless --force. Never prints
# values. Use when onboarding a project (see references/init-project.md) or bulk-loading secrets.
#
# Usage:
#   vault-import.sh <stage> [--service <ns>] [--force] [--dry-run] [FILE]
#   cat secrets.env | vault-import.sh sandbox --service lunai.care

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/kc-lib.sh"

STAGE=""; SVC=""; FORCE=0; DRY=0; FILE=""
while [[ $# -gt 0 ]]; do case "$1" in
  --service) SVC="$2"; shift 2 ;;
  --force)   FORCE=1; shift ;;
  --dry-run) DRY=1; shift ;;
  -*) echo "unknown flag: $1" >&2; exit 2 ;;
  *) if [[ -z "$STAGE" ]]; then STAGE="$1"; else FILE="$1"; fi; shift ;;
esac; done
case "$STAGE" in production|sandbox|common) ;; *) echo "usage: $0 <production|sandbox|common> [--service X] [--force] [FILE]" >&2; exit 2 ;; esac
SERVICE="$(pick_service "$SVC")"
[[ -n "$SERVICE" ]] || { echo "no service: pass --service, set SECRETS_VAULT_SERVICE, or run inside a project" >&2; exit 2; }

incoming="$(cat -- "${FILE:-/dev/stdin}")"
current="$(vault_get "$SERVICE" "$STAGE" 2>/dev/null || true)"

added=0 same=0 conflict=0 forced=0
while IFS= read -r k; do
  [[ -z "$k" ]] && continue
  newv="$(de_get "$incoming" "$k")"
  if de_has "$current" "$k"; then
    oldv="$(de_get "$current" "$k")"
    if [[ "$oldv" == "$newv" ]]; then ((same++)) || true; continue; fi
    if [[ "$FORCE" == 1 ]]; then
      current="$(printf '%s\n' "$current" | awk -v k="$k" -v val="$newv" 'BEGIN{FS=OFS="="} $1==k{print k"="val;next}{print}')"
      ((forced++)) || true
    else
      echo "CONFLICT $k (exists with different value — use --force to overwrite)" >&2
      ((conflict++)) || true
    fi
  else
    current="$(printf '%s\n%s=%s' "$current" "$k" "$newv")"
    ((added++)) || true
  fi
done < <(de_keys "$incoming")

# tidy: drop a possible leading blank line, stable sort
current="$(printf '%s\n' "$current" | grep -vE '^[[:space:]]*$' | sort)"

echo "service=$SERVICE stage=$STAGE  added=$added overwritten=$forced unchanged=$same conflicts=$conflict"
if [[ "$DRY" == 1 ]]; then echo "(dry-run — vault not modified)"; exit 0; fi
if (( conflict > 0 )); then echo "not saved: resolve conflicts or pass --force" >&2; exit 1; fi
vault_put "$SERVICE" "$STAGE" "$current"
echo "saved $SERVICE/$STAGE ($(de_count "$current") keys)"
