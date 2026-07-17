#!/usr/bin/env bash
# Edit a vault stage by hand: decrypt into a 0600 temp file, open $EDITOR, store back on
# save. The temp file is removed on exit. Primary way to add values / fill blanks / rotate.
#
# Safety: adding keys / filling blanks saves freely. Removing a key, blanking it, or changing
# an existing NON-BLANK value is destructive — it prints a loud warning and requires typing
# 'overwrite' at the TTY before saving (guards against a scripted/empty $EDITOR wiping values).
# Pass --yes to skip the prompt (e.g. an intentional non-interactive removal).
#
# Usage:
#   vault-edit.sh <stage> [--service <namespace>] [--yes] [--new-service]
#   service resolves from: --service | $SECRETS_VAULT_SERVICE | current worktree's manifest.yaml

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/kc-lib.sh"

STAGE=""; SVC=""; YES=0; NEWSVC=0
while [[ $# -gt 0 ]]; do case "$1" in
  --service) SVC="$2"; shift 2 ;;
  --yes) YES=1; shift ;;
  --new-service) NEWSVC=1; shift ;;
  -*) echo "unknown flag: $1" >&2; exit 2 ;;
  *) STAGE="$1"; shift ;;
esac; done
case "$STAGE" in production|sandbox|common) ;; *)
  echo "usage: $0 <production|sandbox|common> [--service X] [--new-service]" >&2; exit 2 ;;
esac
SERVICE="$(pick_service "$SVC")"
[[ -n "$SERVICE" ]] || { echo "no service: pass --service, set SECRETS_VAULT_SERVICE, or run inside a project" >&2; exit 2; }
vault_require_age
vault_check_migration "$SERVICE"
vault_ensure_service "$SERVICE" "$NEWSVC" "$YES"

tmp="$(mktemp "${TMPDIR:-/tmp}/vault-${STAGE}.XXXXXX")"; chmod 600 "$tmp"
trap 'rm -f "$tmp"' EXIT
before_blob=""
if before_blob="$(vault_get "$SERVICE" "$STAGE" 2>/dev/null)"; then printf '%s' "$before_blob" >"$tmp"; fi
before="$(shasum "$tmp" | awk '{print $1}')"

"${EDITOR:-vi}" "$tmp"

after="$(shasum "$tmp" | awk '{print $1}')"
if [[ "$before" == "$after" ]]; then echo "no changes — $SERVICE/$STAGE untouched"; exit 0; fi
after_blob="$(cat "$tmp")"

# Detect destructive changes: existing NON-BLANK values removed, blanked, or changed.
mask() { local v="$1"; [[ -z "$v" ]] && { printf '(blank)'; return; }; (( ${#v} <= 4 )) && { printf '****'; return; }; printf '%s…(%d)' "${v:0:2}" "${#v}"; }
destructive=()
while IFS= read -r k; do
  [[ -z "$k" ]] && continue
  oldv="$(de_get "$before_blob" "$k")"; [[ -z "$oldv" ]] && continue
  if ! de_has "$after_blob" "$k"; then destructive+=("$k"$'\t'"$(mask "$oldv")"$'\t'"(removed)")
  else newv="$(de_get "$after_blob" "$k")"; [[ "$newv" != "$oldv" ]] && destructive+=("$k"$'\t'"$(mask "$oldv")"$'\t'"$(mask "$newv")"); fi
done < <(de_keys "$before_blob")

if (( ${#destructive[@]} > 0 )); then
  {
    echo ""
    echo "════════════════════════════════════════════════════════════════════════"
    echo "⚠️  DESTRUCTIVE EDIT — ${#destructive[@]} existing non-blank value(s) in $SERVICE/$STAGE:"
    for d in "${destructive[@]}"; do IFS=$'\t' read -r dk dold dnew <<<"$d"; printf '      %-30s %s  ->  %s\n' "$dk" "$dold" "$dnew"; done
    echo "════════════════════════════════════════════════════════════════════════"
  } >&2
  if [[ "$YES" != 1 ]]; then
    ans=""
    read -r -p "Type 'overwrite' to confirm these removals/changes: " ans </dev/tty 2>/dev/null \
      || { echo "aborted: not a TTY and no --yes — $SERVICE/$STAGE untouched" >&2; exit 1; }
    [[ "$ans" == "overwrite" ]] || { echo "aborted — $SERVICE/$STAGE untouched" >&2; exit 1; }
  fi
fi

vault_put "$SERVICE" "$STAGE" "$after_blob"
echo "saved $SERVICE/$STAGE ($(de_count "$after_blob") keys)"
