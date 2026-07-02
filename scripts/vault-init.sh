#!/usr/bin/env bash
# One-time setup of the vault's age identity — run once per vault, and once per new Mac.
#
#   vault-init.sh              generate a new identity: cache it in the login Keychain,
#                              write recipient.txt (public key) and identity.age (the
#                              identity encrypted with a recovery passphrase) to $VAULT_DIR
#   vault-init.sh --recover    new Mac / lost Keychain: decrypt identity.age with the
#                              recovery passphrase and re-cache it in the login Keychain
#
# The recovery passphrase is the ONLY way back in if the Mac is lost — keep it in your
# head or a personal password manager, never in a repo.
#
# Usage: vault-init.sh [--recover] [--vault-dir <dir>]   (dir also via $SECRETS_VAULT_DIR)

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/kc-lib.sh"

RECOVER=0
while [[ $# -gt 0 ]]; do case "$1" in
  --recover)   RECOVER=1; shift ;;
  --vault-dir) VAULT_DIR="$2"; shift 2 ;;
  *) echo "usage: $0 [--recover] [--vault-dir <dir>]" >&2; exit 2 ;;
esac; done

vault_require_age
[[ -r /dev/tty ]] || { echo "vault-init needs a terminal (passphrase prompt)" >&2; exit 1; }

if [[ "$RECOVER" == 1 ]]; then
  _vault_materialize "$VAULT_DIR/identity.age" \
    || { echo "no identity.age in $VAULT_DIR — has iCloud Drive finished syncing?" >&2; exit 1; }
  echo "Enter the recovery passphrase to unlock $VAULT_DIR/identity.age"
  id="$(age -d "$VAULT_DIR/identity.age" | grep -m1 '^AGE-SECRET-KEY-1')" \
    || { echo "decryption failed (wrong passphrase?)" >&2; exit 1; }
  printf '%s\n' "$id" | age-keygen -y >/dev/null \
    || { echo "decrypted data is not a valid age identity" >&2; exit 1; }
  _kc_identity_put "$id"
  if [[ ! -f "$VAULT_DIR/recipient.txt" ]]; then
    printf '%s\n' "$id" | age-keygen -y >"$VAULT_DIR/recipient.txt.tmp.$$" \
      && mv "$VAULT_DIR/recipient.txt.tmp.$$" "$VAULT_DIR/recipient.txt"
  fi
  echo "recovered — identity cached in the login Keychain; vault commands work prompt-free now"
  exit 0
fi

# fresh init: never overwrite an existing identity
if _kc_identity_get >/dev/null 2>&1; then
  echo "an identity is already cached in the login Keychain — nothing to do" >&2
  echo "(recovering on a new Mac? that uses --recover; replacing the identity would orphan every existing vault file)" >&2
  exit 1
fi
if [[ -f "$VAULT_DIR/identity.age" ]]; then
  echo "$VAULT_DIR/identity.age already exists — run vault-init.sh --recover to unlock it here" >&2
  exit 1
fi

mkdir -p "$VAULT_DIR"
tmpid="$(mktemp "${TMPDIR:-/tmp}/vault-identity.XXXXXX")"; chmod 600 "$tmpid"
trap 'rm -f "$tmpid"' EXIT

age-keygen >"$tmpid" 2>/dev/null
id="$(grep -m1 '^AGE-SECRET-KEY-1' "$tmpid")"
recipient="$(age-keygen -y "$tmpid")"

printf '%s\n' "$recipient" >"$VAULT_DIR/recipient.txt.tmp.$$" \
  && mv "$VAULT_DIR/recipient.txt.tmp.$$" "$VAULT_DIR/recipient.txt"

echo "Choose a recovery passphrase for identity.age (needed only on a new Mac — do not lose it):"
age -p -o "$VAULT_DIR/.identity.age.tmp.$$" "$tmpid" \
  || { rm -f "$VAULT_DIR/.identity.age.tmp.$$"; echo "passphrase entry failed" >&2; exit 1; }
chmod 600 "$VAULT_DIR/.identity.age.tmp.$$"
mv "$VAULT_DIR/.identity.age.tmp.$$" "$VAULT_DIR/identity.age"

_kc_identity_put "$id"

echo ""
echo "vault initialized: $VAULT_DIR"
echo "  recipient.txt  public key (writes encrypt with this)"
echo "  identity.age   passphrase-encrypted recovery copy of the private key"
echo "  Keychain       plaintext key cached for prompt-free daily use"
echo ""
echo "Recovery on a new Mac: sign in to iCloud, wait for $VAULT_DIR to sync,"
echo "run vault-init.sh --recover and enter the passphrase."
