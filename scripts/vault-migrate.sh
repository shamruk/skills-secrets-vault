#!/usr/bin/env bash
# One-time migration of vault data from the legacy storage (macOS login Keychain records)
# into the age-encrypted vault at $VAULT_DIR. Requires vault-init.sh to have been run first.
#
# Non-destructive: Keychain records are read, never deleted. An existing .age stage file is
# never overwritten (skipped with a warning). After verifying with vault-list.sh /
# vault-show.sh, remove the legacy records with the printed cleanup commands.
#
# Usage:
#   vault-migrate.sh [--dry-run]                  auto-discover legacy services (dump-keychain)
#   vault-migrate.sh --service <ns> [--service <ns2> ...] [--dry-run]

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/kc-lib.sh"

SERVICES=(); DRY=0
while [[ $# -gt 0 ]]; do case "$1" in
  --service) SERVICES+=("$2"); shift 2 ;;
  --dry-run) DRY=1; shift ;;
  *) echo "usage: $0 [--service <ns>]... [--dry-run]" >&2; exit 2 ;;
esac; done

vault_require_age
identity_load >/dev/null || { echo "run vault-init.sh first (no vault identity)" >&2; exit 1; }

if [[ ${#SERVICES[@]} -eq 0 ]]; then
  # Discover legacy services: attribute-only dump (no secrets), records whose kind
  # ("desc") is the legacy marker. The identity cache item has a different kind.
  echo "scanning login Keychain for legacy secrets-vault records..."
  discovered="$(security dump-keychain 2>/dev/null | awk -v kind="$KC_KIND" '
    /^keychain:/ { if (d==kind && s!="") print s; d=""; s="" }
    /"desc"<blob>=/ { v=$0; sub(/.*="/,"",v); sub(/"$/,"",v); d=v }
    /"svce"<blob>=/ { v=$0; sub(/.*="/,"",v); sub(/"$/,"",v); s=v }
    END { if (d==kind && s!="") print s }' | sort -u)"
  if [[ -z "$discovered" ]]; then
    echo "no legacy records found — nothing to migrate (or pass --service <ns> explicitly)"
    exit 0
  fi
  while IFS= read -r s; do [[ -n "$s" ]] && SERVICES+=("$s"); done <<<"$discovered"
fi

echo "services to migrate: ${SERVICES[*]}"
migrated=0; skipped=0; absent=0
cleanup=()
for svc in "${SERVICES[@]}"; do
  for st in "${KC_STAGES[@]}"; do
    if ! blob="$(kc_get "$svc" "$st")"; then ((absent++)) || true; continue; fi
    if vault_exists "$svc" "$st"; then
      echo "  SKIP $svc/$st — already in the age vault (won't overwrite with Keychain data)" >&2
      ((skipped++)) || true; continue
    fi
    if [[ "$DRY" == 1 ]]; then
      echo "  would migrate $svc/$st ($(de_count "$blob") keys)"
    else
      VAULT_ALLOW_NEW_SERVICE=1 vault_put "$svc" "$st" "$blob"
      back="$(vault_get "$svc" "$st")"
      [[ "$back" == "$blob" ]] || { echo "  VERIFY FAILED for $svc/$st — round-trip mismatch, aborting" >&2; exit 1; }
      echo "  migrated $svc/$st ($(de_count "$blob") keys)"
    fi
    ((migrated++)) || true
    cleanup+=("security delete-generic-password -D '$KC_KIND' -s '$svc' -a '$st'")
  done
done

echo ""
echo "migrated=$migrated skipped=$skipped absent=$absent  ->  $VAULT_DIR"
[[ "$DRY" == 1 ]] && { echo "(dry-run — nothing written)"; exit 0; }
if (( ${#cleanup[@]} > 0 )); then
  echo ""
  echo "Legacy Keychain records were left in place. After verifying (vault-list.sh /"
  echo "vault-show.sh --mask), remove them with:"
  for c in "${cleanup[@]}"; do echo "  $c"; done
fi
