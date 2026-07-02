# secrets-vault

A tiny, dependency-light secrets manager for solo developers and small teams:
**[age](https://github.com/FiloSottile/age)-encrypted files** in a local vault **mirrored to
iCloud Drive** for durability, the **macOS login Keychain** for prompt-free daily use, and a
set of bash scripts that sync secrets to **Cloudflare Workers, GitHub Actions, Codemagic,
Appwrite, or local `.env`/`.dev.vars` files** — per project, per stage.

Built as a [Claude Code](https://claude.com/claude-code) skill, but every script works
standalone from any shell.

```
      daily use (no prompts, no TCC)          durability                disaster recovery
┌──────────────┐ identity ┌────────────────┐   mirror   ┌────────────┐ ┌──────────────────────┐
│ login        │ ───────▶ │ ~/.secrets-    │ ─────────▶ │ iCloud     │ │ new Mac              │
│ Keychain     │  decrypt │  vault/        │  on every  │ Drive      │ │  1. sign in to iCloud│
│ (this Mac)   │          │  ├ recipient   │   write    │ secrets-   │▶│  2. vault-init.sh    │
└──────────────┘          │  ├ identity.age│            │ vault/     │ │     --recover        │
      ▲                   │  └ acme.dev/   │ ◀───────── │ (same      │ │  3. one passphrase   │
      └─ cached on unlock │    ├ prod .age │  pull on   │  files)    │ │  → everything back   │
                          │    └ sand .age │  new Mac   └────────────┘ └──────────────────────┘
                          └────────────────┘
```

## Why

- **Lose the laptop, keep the secrets.** A tiny background agent mirrors every vault write to
  iCloud. With an Apple Developer account it's the iOS-style clean version: a signed helper
  scoped to **its own iCloud container** ("Secrets Vault" folder in iCloud Drive) — zero
  macOS permission prompts, no access to anything else. Without one, an applet fallback
  mirrors to a plain iCloud Drive folder (one Files & Folders grant). Either way, if backup
  ever stalls you get an on-screen dialog, not a log line. Recovery on a new Mac = iCloud
  sign-in + one passphrase.
- **No prompts in daily work — and no macOS permission walls.** The age identity is cached in
  the login Keychain; scripts decrypt silently. The working copy lives at `~/.secrets-vault`
  (a plain home dir), so sandboxed/headless processes never hit the per-app TCC gate that
  guards iCloud Drive. Writes need only the *public* key.
- **No vendor, no service, no subscription.** Plain `age` files you can decrypt by hand with
  one command, forever. The mirror works with any synced/backed-up folder
  (`$SECRETS_VAULT_CLOUD_DIR`), not just iCloud.
- **Secrets never touch your repos.** Repos commit only non-secret metadata: which keys each
  deploy target needs, and non-secret variables.
- **One vault, many projects.** Related repos share a *service* namespace; each key exists
  once per stage (`production` / `sandbox` / `common`) with environment-neutral names.

## Install

```bash
brew install age jq
git clone https://github.com/shamruk/skills-secrets-vault ~/.claude/skills/secrets-vault
~/.claude/skills/secrets-vault/scripts/vault-init.sh   # once: choose a recovery passphrase
```

Cloning into `~/.claude/skills/` makes it a Claude Code skill ("rotate the Stripe key on
sandbox", "apply the cloudflare scope to production"); anywhere else, just call the scripts.

## The model in 60 seconds

Each **project** commits an `environments/` folder:

```
environments/
  manifest.yaml        # service: acme.dev   repo: my-worker     (metadata only)
  variables            # non-secret KEY=VALUE, committed
  variables.sandbox    # per-stage overrides, committed
  cloudflare           # a "scope": the keys one deploy target needs
```

A **scope** lists keys and where they go:

```
# target: cloudflare
STRIPE_SECRET_KEY                          # secret — resolved from the vault
SITE_URL                                   # variable — resolved from variables files
PROD_DB_PASSWORD = DB_PASSWORD@production  # rename + pin to a stage
```

The engine resolves every key (vault → secret, variables file → variable) and routes it:

```bash
scripts/secrets.sh check  my-worker/cloudflare --stage sandbox   # ok/BLANK per key, no side effects
scripts/secrets.sh apply  my-worker/cloudflare --stage sandbox   # wrangler secret put …
scripts/secrets.sh apply  my-app/gha --stage production          # gh secret set / gh variable set
scripts/secrets.sh apply  my-app/dev --stage sandbox             # render .dev.vars locally
```

Vault maintenance:

```bash
scripts/vault-list.sh --all              # every service, key counts — never values
scripts/vault-edit.sh sandbox            # $EDITOR on the decrypted stage, guarded save
scripts/vault-import.sh sandbox FILE     # merge a dotenv file, conflict-aware
scripts/vault-show.sh sandbox --mask     # peek without exposing values
scripts/vault-delete.sh sandbox          # typed-confirmation delete
```

## Safety rails

- Overwriting or deleting an existing non-blank secret requires typing `overwrite` (or
  `delete <service>/<stage>`) at the TTY; `--yes` is the explicit automation opt-in. No TTY
  and no `--yes` → abort, never clobber.
- A typo'd `--service` can't silently create a new namespace (`--new-service` required).
- Plaintext never appears in process argument lists (`ps`-safe): everything moves via stdin,
  files, and the environment.
- Comments, blank lines and key order you add in `vault-edit` survive future imports.
- `vault-migrate.sh` (from the older Keychain-record backend) is non-destructive and
  round-trip-verifies every stage before reporting success.

## Manual access (no tooling required)

The vault is just age files. With the Keychain-cached identity:

```bash
age -d -i <(security find-generic-password -s secrets-vault -a age-identity -w | xxd -r -p) \
  ~/.secrets-vault/acme.dev/sandbox.age
```

Or from nothing but the iCloud mirror and your passphrase:

```bash
age -d -i <(age -d identity.age) acme.dev/sandbox.age
```

## Requirements

macOS (bash 3.2-compatible), `age`, `jq`; plus per-target CLIs you actually use:
`wrangler` (via `npx`), `gh`, `curl`. YAML parsing falls back ruby → yq → python3+PyYAML.

## Docs

- [SKILL.md](SKILL.md) — full command reference, scope-file syntax, multi-repo/submodule rules
- [references/init-project.md](references/init-project.md) — onboarding a new project step by step
