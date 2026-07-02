# secrets-vault internals

How the vault actually works. Read this only when debugging, when a vault command misbehaves,
or when modifying the skill itself — using the skill never requires it.

## Storage model

- **Vault** = a directory of [age](https://github.com/FiloSottile/age)-encrypted files:
  `$VAULT_DIR/<service>/<stage>.age`, one encrypted dotenv blob per (service, stage).
- **Two locations** (both plain files, kept in sync by the lib):
  - **Primary** `$VAULT_DIR`, default `~/.secrets-vault` (override `$SECRETS_VAULT_DIR`).
    A plain home dir on purpose: macOS TCC gates iCloud Drive *per app* and checks the
    resolved path (symlinks don't dodge it), so headless/sandboxed processes get EPERM
    inside `~/Library/Mobile Documents`. All reads/writes hit the primary — no permission
    prompts ever.
  - **Mirror** `$VAULT_CLOUD_DIR`, default the iCloud Drive `secrets-vault/` folder
    (override `$SECRETS_VAULT_CLOUD_DIR`; `none` disables). Durability copy — this is what
    survives losing the Mac.
- **Sync**: every `vault_put` mirrors the written file (atomic cp+mv, content-compared). If
  the mirror is unreachable (TCC-blocked app), the write still succeeds locally, a
  `.mirror-pending` marker is set, and the next vault write from a permitted app — or
  `vault-sync.sh` — flushes everything pending. Reads fall back: a file missing from the
  primary is pulled in from the mirror (`_cloud_pull`). `vault-sync.sh --pull` localizes a
  whole vault on a new machine (primary always wins; pull never overwrites).
- **One X25519 age identity for the whole vault**, held in three places:
  - `recipient.txt` (primary + mirror) — the public key. Every write encrypts with this, so
    writing never needs the secret identity. Public-safe. Regenerated from the identity if
    missing.
  - macOS **login Keychain** item (`-s secrets-vault -a age-identity`,
    kind `secrets-vault-identity`) — the plaintext identity, cached for prompt-free reads.
    Stored hex-encoded and written via `security -i` on stdin so it never appears in argv.
  - `identity.age` (primary + mirror) — the identity encrypted with a user passphrase
    (`age -p`, scrypt). The disaster-recovery copy; the mirror copy is the one that matters.
    Useless without the passphrase.
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

## iCloud specifics (mirror dir only)

- **TCC**: iCloud Drive access is granted per responsible app; denials persist and headless
  processes can't answer the prompt. This is why the primary lives outside it. A mirror
  failure is never fatal — the local write wins and syncing self-heals.
- Evicted ("dataless") files: `_vault_materialize` detects the `.<name>.icloud` placeholder,
  calls `brctl download`, and polls up to ~20 s before failing with a friendly error. On
  non-iCloud dirs it's a no-op. (Note: some macOS builds ship a `brctl` without a `download`
  subcommand; reading the path usually triggers materialization anyway.)
- Conflict copies (`<stage> 2.age`) are skipped by `vault_services`; resolve manually —
  single-writer assumption.
- "Keep Downloaded" pinning is Finder-only; Apple exposes no CLI/API for it. The files are
  tiny (~hundreds of bytes), so eviction is unlikely regardless.

## Signed helper — container mode (preferred)

`SecretsVaultHelper.app` (built by `scripts/build-helper.sh` from `scripts/helper-src/`,
SwiftPM) mirrors the vault into **its own iCloud ubiquity container** — the iOS model:

- Bundle `com.shamruk.secrets-vault-sync`, container `iCloud.com.shamruk.secrets-vault-sync`,
  team `UA5Q77U2KN`. Signed **Developer ID Application** with a **Developer ID provisioning
  profile** (expires 2044, all devices — no annual rebuild) carrying
  `icloud-container-identifiers`, `ubiquity-container-identifiers`,
  `icloud-services=[CloudDocuments]`. Profile lives at
  `~/Library/Application Support/secrets-vault/secrets-vault-sync.provisionprofile`
  (gitignored; regenerate on the Apple portal: the App ID's iCloud capability must have the
  container **assigned via Edit/Configure**, else the profile's container arrays are empty
  and the container URL resolves nil).
- Container on disk: `~/Library/Mobile Documents/iCloud~com~shamruk~secrets-vault-sync/
  Documents/vault/<service>/<stage>.age` (+ `identity.age`, `recipient.txt`, `README.txt`).
  `NSUbiquitousContainers` in Info.plist (`IsDocumentScopePublic`, name "Secrets Vault")
  makes it visible in Finder's iCloud Drive; `CFBundleVersion` is bumped every build so
  changes take effect.
- **Zero TCC**: the entitlement authorizes the app's own container; no prompts, no Settings
  entries, no access to anything else. Other processes (shells) still can't read the
  container — that's the point; they go through the helper (`sync`/`pull`/`path`).
- Writes use `NSFileCoordinator`; deletions mirror (primary wins); dataless files are
  materialized with a bounded wait (only when a `.name.icloud` placeholder exists).
- In helper mode, `kc-lib` does **no inline mirroring** — `vault_put`/`vault_delete_stage`
  just touch `$VAULT_DIR/.last-write` and the agent syncs within ~1 min (ThrottleInterval).
  `_cloud_pull`/`vault-sync.sh` delegate to the helper when present.

## Background sync agent (`vault-agent.sh`) — applet fallback

For Macs without the signing cert/profile, `install` falls back to the AppleScript applet +
iCloud Drive folder mode below. Covers the case where *no* vault-writing process ever has
iCloud access (all headless/sandboxed): without an agent the mirror would go stale with only
log warnings nobody reads.

- **Why an .app**: TCC never prompts for non-app processes — a bash LaunchAgent is denied
  *silently*, and granting `/bin/bash` Full Disk Access would be over-broad. `install`
  compiles a local AppleScript applet (`osacompile`) at
  `~/Library/Application Support/secrets-vault/SecretsVaultSync.app` (`LSUIElement=1`,
  bundle id `dev.secrets-vault.sync`, ad-hoc signed). As a real app it can raise the normal
  on-screen permission prompt, hold a persistent grant, and appear by name in System
  Settings.
- **LaunchAgent** `~/Library/LaunchAgents/dev.secrets-vault.sync.plist`: runs the applet
  binary directly; `WatchPaths` on `$VAULT_DIR` + `StartInterval` 3600 + `RunAtLoad`;
  `ThrottleInterval` 60; log at `~/Library/Logs/secrets-vault-sync.log`.
- **Trigger**: `vault_put` writes `$VAULT_DIR/.last-write` after every local write —
  WatchPaths is non-recursive, so a root-level file is needed to fire on stage writes in
  subdirectories.
- **Applet behavior**: runs `vault-sync.sh --agent` (quiet on success, records
  `last-sync` in the app-support dir). On failure it shows a `display dialog` — "iCloud
  backup is not updating … data safe locally" with an **Open Settings** button (deep link
  `…?Privacy_FilesAndFolders`) — throttled to once per 6 h via a `last-nag` timestamp.
  Problems land on the user's screen, never only in logs. (`display notification` is
  deliberately not used — unreliable from applets.)
- **Permissions**: the narrow, correct grant is Files & Folders → SecretsVaultSync →
  iCloud Drive, obtained via the normal on-screen prompt on first access (confirmed
  working). Full Disk Access is NOT required — never advise it for this agent.
- Re-running `install` rebuilds the app; macOS may show the permission prompt once more
  (the grant is keyed to the signature).

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
| `SECRETS_VAULT_DIR` | primary vault location (default `~/.secrets-vault`) |
| `SECRETS_VAULT_CLOUD_DIR` | mirror location (default iCloud Drive `secrets-vault/`; `none` disables) |
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
| `scripts/vault-sync.sh` | reconcile primary ↔ mirror (push, `--pull`, `--agent`; delegates to helper) |
| `scripts/vault-agent.sh` | background mirror agent (install/status/uninstall; helper or applet mode) |
| `scripts/build-helper.sh` | build + Developer-ID-sign SecretsVaultHelper.app |
| `scripts/helper-src/` | SwiftPM source of the container-scoped helper |
| `scripts/vault-migrate.sh` | one-time legacy Keychain → vault migration |
| `scripts/yaml2json` | YAML shim (ruby → yq → python3+PyYAML) for `manifest.yaml` |

Requirements: macOS, bash 3.2-compatible scripts, `age`/`age-keygen` (brew), `jq`; per-target
CLIs (`npx wrangler`, `gh`, `curl`) only when that target is used.
