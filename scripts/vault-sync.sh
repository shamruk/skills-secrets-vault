#!/usr/bin/env bash
# Reconcile the primary vault with its iCloud mirror.
#
#   vault-sync.sh          push: copy every primary file that differs to the mirror
#                          (runs automatically after each vault write; use this when a write
#                          from a permission-restricted app warned that mirroring failed)
#   vault-sync.sh --pull   pull: copy mirror files missing from the primary (new machine,
#                          or a vault written on another Mac). Never overwrites a primary
#                          file that already exists — the primary wins.
#
#   vault-sync.sh --agent  same as push but for the background LaunchAgent: quiet on success,
#                          records the sync time, exit 1 on any mirror failure
#
# Usage: vault-sync.sh [--pull | --agent]

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/kc-lib.sh"

PULL=0; AGENT=0
while [[ $# -gt 0 ]]; do case "$1" in
  --pull)  PULL=1; shift ;;
  --agent) AGENT=1; shift ;;
  *) echo "usage: $0 [--pull | --agent]" >&2; exit 2 ;;
esac; done

_cloud_enabled || { [[ "$AGENT" == 1 ]] || echo "no mirror configured (SECRETS_VAULT_CLOUD_DIR=none)"; exit 0; }

if [[ "$AGENT" == 1 ]]; then
  [[ -d "$VAULT_DIR" ]] || exit 0                      # nothing to back up yet
  state_dir="$HOME/Library/Application Support/secrets-vault"
  if _mirror_sweep; then
    mkdir -p "$state_dir"; date +%s >"$state_dir/last-sync"
    exit 0
  fi
  echo "agent: mirror push failed ($VAULT_DIR -> $VAULT_CLOUD_DIR)" >&2
  exit 1
fi

if [[ "$PULL" == 1 ]]; then
  [[ -d "$VAULT_CLOUD_DIR" ]] || { echo "mirror not found: $VAULT_CLOUD_DIR (iCloud still syncing?)" >&2; exit 1; }
  pulled=0; kept=0; failed=0
  while IFS= read -r f; do
    rel="${f#"$VAULT_CLOUD_DIR"/}"
    case "$rel" in .*|*/.*) continue ;; esac
    if [[ -f "$VAULT_DIR/$rel" ]]; then ((kept++)) || true; continue; fi
    if _cloud_pull "$rel"; then echo "  pulled $rel"; ((pulled++)) || true
    else ((failed++)) || true; fi
  done < <(find "$VAULT_CLOUD_DIR" -type f \( -name '*.age' -o -name recipient.txt \) 2>/dev/null)
  echo "pull: pulled=$pulled kept-local=$kept failed=$failed  ($VAULT_CLOUD_DIR -> $VAULT_DIR)"
  [[ "$failed" == 0 ]] || exit 1
else
  [[ -d "$VAULT_DIR" ]] || { echo "no primary vault at $VAULT_DIR — run vault-init.sh" >&2; exit 1; }
  if _mirror_sweep; then
    echo "push: mirror is up to date  ($VAULT_DIR -> $VAULT_CLOUD_DIR)"
  else
    echo "push: some files could not be mirrored — this app may lack iCloud Drive access; try from a normal terminal" >&2
    exit 1
  fi
fi
