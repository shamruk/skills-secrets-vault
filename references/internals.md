# secrets-vault internals

How the vault actually works. Read this only when debugging, when a vault command misbehaves,
or when modifying the skill itself — using the skill never requires it.

## Storage model

- **Vault** = a directory of [age](https://github.com/FiloSottile/age)-encrypted files:
  `$VAULT_DIR/<service>/<stage>.age`, one encrypted dotenv blob per (service, stage).
  `VAULT_DIR` defaults to `~/Library/Mobile Documents/com~apple~CloudDocs/secrets-vault`
  (iCloud Drive → survives losing the machine); override with `$SECRETS_VAULT_DIR` (any dir
  works, e.g. a git repo or another synced folder).
- **One X25519 age identity for the whole vault**, held in three places:
  - `$VAULT_DIR/recipient.txt` — the public key. Every write encrypts with this, so writing
    never needs the secret identity. Public-safe. Regenerated from the identity if missing.
  - macOS **login Keychain** item (`-s secrets-vault -a age-identity`,
    kind `secrets-vault-identity`) — the plaintext identity, cached for prompt-free reads.
    Stored hex-encoded and written via `security -i` on stdin so it never appears in argv.
  - `$VAULT_DIR/identity.age` — the identity encrypted with a user passphrase (`age -p`,
    scrypt). The disaster-recovery copy; syncs beside the vault. Useless without the
    passphrase.
- **Identity resolution order** (`identity_load` in `kc-lib.sh`, memoized per process):
  `$SECRETS_VAULT_IDENTITY_FILE` (tests/CI escape hatch; Keychain never touched) → Keychain
  cache → decrypt `identity.age` (passphrase prompt on TTY, then re-cache into the Keychain)
  → error pointing at `vault-init.sh`. No TTY + nothing cached ⇒ clear error, never hangs.

## Write path & guards

- `vault_put` encrypts with `age -e -R recipient.txt` to a `.tmp.$$` file in the same
  directory, `chmod 600`, then atomic `mv` (last-writer-wins; acceptable single-user).
- Creating a service directory that doesn't exist requires `VAULT_ALLOW_NEW_SERVICE=1`, set
  only by `vault_ensure_service` (the `--new-service` flag / TTY confirm) — the typo guard.
- Plaintext never on argv anywhere: blobs via stdin/`-o`, identity via process substitution
  (`age -d -i <(...)`), awk value injection via `ENVIRON` (also keeps backslashes intact).
- `vault-import`/`vault-edit` preserve blob structure: existing keys are rewritten in place,
  new keys appended; no sorting, comments and blank lines survive.

## iCloud specifics

- Evicted ("dataless") files: `_vault_materialize` detects the `.<name>.icloud` placeholder,
  calls `brctl download`, and polls up to ~20 s before failing with a friendly error. On
  non-iCloud dirs it's a no-op. (Note: some macOS builds ship a `brctl` without a `download`
  subcommand; reading the path usually triggers materialization anyway.)
- Conflict copies (`<stage> 2.age`) are skipped by `vault_services`; resolve manually —
  single-writer assumption.
- "Keep Downloaded" pinning is Finder-only; Apple exposes no CLI/API for it. The files are
  tiny (~hundreds of bytes), so eviction is unlikely regardless.

## Legacy migration (pre-age backend)

The previous backend stored each (service, stage) as a login-Keychain generic-password record
(kind `secrets-vault`, service = namespace, account = stage). `vault-migrate.sh`:

- discovers legacy services via `security dump-keychain` (attributes only, no secret material),
  filtering records whose `"desc"` is `secrets-vault`;
- copies each stage into the vault with a round-trip verification, **never overwriting** an
  existing `.age` file;
- leaves Keychain records in place and prints per-record `security delete-generic-password`
  cleanup commands to run after verification.

`vault_check_migration` (called by every vault command after resolving the service) refuses to
operate on a service that has legacy records but no `.age` files — you can't accidentally work
against an empty new vault while real data sits in the Keychain.

## Manual access without the tooling

With the Keychain-cached identity (the value is hex-encoded, hence `xxd`):

```bash
age -d -i <(security find-generic-password -s secrets-vault -a age-identity -w | xxd -r -p) \
  "$VAULT_DIR/<service>/<stage>.age"
```

From nothing but the synced folder + passphrase (e.g. borrowed machine):

```bash
age -d -i <(age -d "$VAULT_DIR/identity.age") "$VAULT_DIR/<service>/<stage>.age"
```

## Environment overrides

| Variable | Effect |
|---|---|
| `SECRETS_VAULT_DIR` | vault location (default: iCloud Drive `secrets-vault/`) |
| `SECRETS_VAULT_IDENTITY_FILE` | read the age identity from this file; Keychain untouched (tests/CI) |
| `SECRETS_VAULT_KC_ACCOUNT` | Keychain account name for the identity cache (tests only) |
| `SECRETS_VAULT_SERVICE` | default service when no `--service`/project context |
| `SECRETS_VAULT_REPOS_ROOT` | root scanned for project manifests (default `~/Projects`) |
| `SECRETS_VAULT_CACHE` / `SECRETS_VAULT_NOCACHE` | repo-index cache location / bypass |

## File map

| File | Role |
|---|---|
| `scripts/kc-lib.sh` | shared lib: storage layer, identity, dotenv/manifest/project helpers |
| `scripts/secrets.sh` | scope engine: check/print/export/apply to targets |
| `scripts/vault-{list,show,edit,import,delete}.sh` | vault CRUD |
| `scripts/vault-init.sh` | identity setup / `--recover` |
| `scripts/vault-migrate.sh` | one-time legacy Keychain → vault migration |
| `scripts/yaml2json` | YAML shim (ruby → yq → python3+PyYAML) for `manifest.yaml` |

Requirements: macOS, bash 3.2-compatible scripts, `age`/`age-keygen` (brew), `jq`; per-target
CLIs (`npx wrangler`, `gh`, `curl`) only when that target is used.
