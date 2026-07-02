#!/usr/bin/env bash
# Merge KEY=VALUE pairs from a dotenv file (or stdin) into a vault stage. Conflict-aware:
# an existing key with a different value is reported and skipped unless --force. Never prints
# values. Use when onboarding a project (see references/init-project.md) or bulk-loading secrets.
#
# Safety: filling a blank or adding a new key is non-destructive. Replacing or blanking an
# existing NON-BLANK value is destructive — even with --force it prints a loud warning and
# requires typing 'overwrite' at the TTY. Pass --yes to skip the prompt (automation; explicit
# opt-in). Without a TTY and without --yes, a destructive overwrite aborts rather than clobber.
#
# Comments/blank lines/ordering in the stored blob are preserved: existing keys are updated
# in place, new keys are appended at the end.
#
# Usage:
#   vault-import.sh <stage> [--service <ns>] [--force] [--yes] [--dry-run] [--new-service] [FILE]
#   cat secrets.env | vault-import.sh sandbox --service acme.dev

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/kc-lib.sh"

STAGE=""; SVC=""; FORCE=0; DRY=0; YES=0; NEWSVC=0; FILE=""
while [[ $# -gt 0 ]]; do case "$1" in
  --service) SVC="$2"; shift 2 ;;
  --force)   FORCE=1; shift ;;
  --dry-run) DRY=1; shift ;;
  --yes)     YES=1; shift ;;
  --new-service) NEWSVC=1; shift ;;
  -*) echo "unknown flag: $1" >&2; exit 2 ;;
  *) if [[ -z "$STAGE" ]]; then STAGE="$1"; else FILE="$1"; fi; shift ;;
esac; done
case "$STAGE" in production|sandbox|common) ;; *) echo "usage: $0 <production|sandbox|common> [--service X] [--force] [--new-service] [FILE]" >&2; exit 2 ;; esac
SERVICE="$(pick_service "$SVC")"
[[ -n "$SERVICE" ]] || { echo "no service: pass --service, set SECRETS_VAULT_SERVICE, or run inside a project" >&2; exit 2; }
vault_require_age
vault_check_migration "$SERVICE"
vault_ensure_service "$SERVICE" "$NEWSVC" "$YES"

incoming="$(cat -- "${FILE:-/dev/stdin}")"
current="$(vault_get "$SERVICE" "$STAGE" 2>/dev/null || true)"

mask() { local v="$1"; [[ -z "$v" ]] && { printf '(blank)'; return; }; (( ${#v} <= 4 )) && { printf '****'; return; }; printf '%s…(%d)' "${v:0:2}" "${#v}"; }

added=0 same=0 conflict=0 forced=0
destructive=()   # existing NON-BLANK values that --force would change/blank (the dangerous subset)
while IFS= read -r k; do
  [[ -z "$k" ]] && continue
  newv="$(de_get "$incoming" "$k")"
  if de_has "$current" "$k"; then
    oldv="$(de_get "$current" "$k")"
    if [[ "$oldv" == "$newv" ]]; then ((same++)) || true; continue; fi
    if [[ "$FORCE" == 1 ]]; then
      # Filling a blank is safe; replacing/blanking an existing non-blank value is destructive.
      [[ -n "$oldv" ]] && destructive+=("$k"$'\t'"$(mask "$oldv")"$'\t'"$(mask "$newv")")
      current="$(printf '%s\n' "$current" | NEWV="$newv" awk -v k="$k" 'BEGIN{FS=OFS="="} $1==k{print k"="ENVIRON["NEWV"];next}{print}')"
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

# tidy: appending to an initially-empty blob leaves a leading blank line — drop it.
# (No sorting/stripping: comments, blank lines and key order in the blob are preserved.)
while [[ "$current" == $'\n'* ]]; do current="${current#$'\n'}"; done

echo "service=$SERVICE stage=$STAGE  added=$added overwritten=$forced unchanged=$same conflicts=$conflict"

# Loud warning + confirmation before destroying any existing non-blank value.
if (( ${#destructive[@]} > 0 )); then
  {
    echo ""
    echo "════════════════════════════════════════════════════════════════════════"
    echo "⚠️  DESTRUCTIVE OVERWRITE — ${#destructive[@]} existing non-blank secret(s) in $SERVICE/$STAGE:"
    for d in "${destructive[@]}"; do IFS=$'\t' read -r dk dold dnew <<<"$d"; printf '      %-30s %s  ->  %s\n' "$dk" "$dold" "$dnew"; done
    echo "   The old value(s) are unrecoverable once overwritten."
    echo "════════════════════════════════════════════════════════════════════════"
  } >&2
fi

if [[ "$DRY" == 1 ]]; then echo "(dry-run — vault not modified)"; exit 0; fi
if (( conflict > 0 )); then echo "not saved: resolve conflicts or pass --force" >&2; exit 1; fi
if (( ${#destructive[@]} > 0 )) && [[ "$YES" != 1 ]]; then
  ans=""
  read -r -p "Type 'overwrite' to confirm and replace the value(s) above: " ans </dev/tty 2>/dev/null \
    || { echo "aborted: not a TTY and no --yes — refusing to overwrite existing secrets" >&2; exit 1; }
  [[ "$ans" == "overwrite" ]] || { echo "aborted" >&2; exit 1; }
fi
vault_put "$SERVICE" "$STAGE" "$current"
echo "saved $SERVICE/$STAGE ($(de_count "$current") keys)"
