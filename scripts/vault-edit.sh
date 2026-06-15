#!/usr/bin/env bash
# Edit a vault stage by hand: decrypt into a 0600 temp file, open $EDITOR, store back on
# save. The temp file is removed on exit. Primary way to add values / fill blanks / rotate.
#
# Usage:
#   vault-edit.sh <stage> [--service <namespace>]
#   service resolves from: --service | $SECRETS_VAULT_SERVICE | nearest project's manifest.yaml

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/kc-lib.sh"

STAGE=""; SVC=""
while [[ $# -gt 0 ]]; do case "$1" in
  --service) SVC="$2"; shift 2 ;;
  -*) echo "unknown flag: $1" >&2; exit 2 ;;
  *) STAGE="$1"; shift ;;
esac; done
case "$STAGE" in production|sandbox|common) ;; *)
  echo "usage: $0 <production|sandbox|common> [--service X]" >&2; exit 2 ;;
esac
SERVICE="$(pick_service "$SVC")"
[[ -n "$SERVICE" ]] || { echo "no service: pass --service, set SECRETS_VAULT_SERVICE, or run inside a project" >&2; exit 2; }

tmp="$(mktemp "${TMPDIR:-/tmp}/vault-${STAGE}.XXXXXX")"; chmod 600 "$tmp"
trap 'rm -f "$tmp"' EXIT
if blob="$(vault_get "$SERVICE" "$STAGE" 2>/dev/null)"; then printf '%s' "$blob" >"$tmp"; fi
before="$(shasum "$tmp" | awk '{print $1}')"

"${EDITOR:-vi}" "$tmp"

after="$(shasum "$tmp" | awk '{print $1}')"
if [[ "$before" == "$after" ]]; then echo "no changes — $SERVICE/$STAGE untouched"; exit 0; fi
vault_put "$SERVICE" "$STAGE" "$(cat "$tmp")"
echo "saved $SERVICE/$STAGE ($(de_count "$(cat "$tmp")") keys)"
