---
name: secrets-vault
description: >-
  Manage project secrets and non-secret variables across any repo/ecosystem, with an
  age-encrypted vault in iCloud Drive as the source of truth for secrets (identity cached in
  the macOS login Keychain). Use when asked to view, edit, rotate, add, or fill in secrets/env
  vars; check/print/export/apply a project's environment scope; sync secrets to Cloudflare
  Workers, GitHub Actions, Appwrite, or a local .env/.dev.vars; or onboard a new project
  ("set up secrets/environments for this repo"). Triggers: secrets, env vars, vault, age,
  Keychain, .env/.dev.vars, "rotate the key", "set the Cloudflare/GitHub secret", production
  vs sandbox credentials; monorepo/submodule projects ("which repo owns this scope?").
---

# secrets-vault

A small bash toolkit. **Secrets** live in an age-encrypted vault in iCloud Drive (survives
losing the machine); **variables** (non-secret) live in committed dotenv files; **scopes**
declare which keys each deploy target needs; the engine resolves a scope and
`check`/`print`/`export`/`apply`s it.

## Model

- **vault** — a directory of age-encrypted files, default
  `~/Library/Mobile Documents/com~apple~CloudDocs/secrets-vault` (override:
  `$SECRETS_VAULT_DIR`; any dir works, iCloud Drive gives off-machine durability).
- **service** — a directory in the vault per ecosystem (e.g. `acme.dev`). Holds 3 **stages**
  (`production.age`, `sandbox.age`, `common.age`), each an encrypted dotenv blob of secret
  values. `common` = identical across stages. Stage is chosen by *which file* you read, so key
  names are environment-neutral.
- **keys** — one age identity for the whole vault:
  `recipient.txt` (public key; all writes encrypt with it), the plaintext identity cached in
  the **login Keychain** for prompt-free daily use, and `identity.age` (the identity encrypted
  with a recovery passphrase) syncing beside the vault. **Lost Mac recovery** = new Mac +
  iCloud sign-in + `vault-init.sh --recover` + the passphrase. Nothing key-related ever lives
  in a repo.
- **variables** — non-secret values committed in `environments/variables` and optional
  `environments/variables.<stage>` (plain `KEY=VALUE`).
- **manifest** — `environments/manifest.yaml` (YAML): `service:` + `repo:` (project metadata).
- **scope** — `environments/<scope>` text file listing the keys a **target** needs.

A key resolves as a **secret** (found in a vault) or a **variable** (found in a variables file);
`apply` routes by source per target.

## Scope file format (`environments/<scope>`)

```
# target: cloudflare        # cloudflare | gha | appwrite | codemagic | local
# wrangler-dir: .           # (cloudflare) dir with wrangler.toml/.jsonc/.json, relative to repo
# wrangler-env: none        # (cloudflare) wrangler named env: omit = --env <stage>;
#                           #   `none` = single top-level Worker (no --env); `<name>` = that env
# github: ORG/REPO          # (gha) GitHub repo
# file: .dev.vars           # (local) dotenv file to render, relative to repo
# app-name: my-app          # (codemagic) target app — or `# app-id: <id>` (explicit)
# group: production         # (codemagic) environment variable group name

STRIPE_SECRET_KEY                       # resolve by this name
OPENROUTER_API_KEY = WORKERS_OPENROUTER_API_KEY   # rename: dest = vault/var key
PROD_DB_PASSWORD   = DB_PASSWORD@production        # cross-stage: pin source to a stage
```

## Commands

Run scripts from `scripts/`. Service is read from the target project's `manifest.yaml`
(or `--service <ns>` / `$SECRETS_VAULT_SERVICE` / the nearest project when in a repo).
Projects are found by scanning `$SECRETS_VAULT_REPOS_ROOT` (default `~/Projects`) for a
`manifest.yaml` whose `repo:` matches.

```bash
scripts/secrets.sh check  <repo>/<scope> --stage <stage>      # resolve, tag secret|variable, no side effects
scripts/secrets.sh print  <repo>/<scope> --stage <stage> [--mask]
scripts/secrets.sh export <repo>/<scope> --stage <stage>      # eval "$(… export …)"
scripts/secrets.sh apply  <repo>/<scope> --stage <stage> [--dry-run] [--yes]

scripts/vault-list.sh [--service <ns>] [--all]                # stages + key counts (no values); --all / no project = every service
scripts/vault-show.sh <stage> [--service <ns>] [--mask] [KEY …]
scripts/vault-edit.sh <stage> [--service <ns>] [--yes] [--new-service]   # $EDITOR a stage; add/rotate/fill blanks
scripts/vault-import.sh <stage> [--service <ns>] [--force] [--yes] [--new-service] [FILE]  # merge a dotenv file into a stage
scripts/vault-delete.sh <stage> [--service <ns>] [--yes]      # delete a stage (typed confirmation)

scripts/vault-init.sh [--recover]                             # once per vault / once per new Mac
scripts/vault-migrate.sh [--service <ns>]... [--dry-run]      # one-time: legacy Keychain -> age vault
```

`apply` routing: **cloudflare** → `wrangler secret put …` (secrets only; vars stay in the wrangler
config). By default targets `--env <stage>` (per-stage named envs); a scope can set `# wrangler-env:
none` for a single top-level Worker (no `--env`) or `# wrangler-env: <name>` to pin a named env.
Config may be `wrangler.toml`, `wrangler.jsonc`, or `wrangler.json`. **gha** → `gh secret set` for
secrets, `gh variable set` for variables;
**local** → merge secrets+variables into the dotenv file (other lines untouched); **appwrite** →
prints masked values to set as function variables (auto-push not wired); **codemagic** → REST API
upsert into the app's env-var group (secret → `secure:true`, variable → `secure:false`); auth via
`$CODEMAGIC_API_TOKEN` or vault/`common` `CODEMAGIC_API_TOKEN`.

## Setup, migration & recovery

- **First time on a machine (new vault):** `brew install age`, then `scripts/vault-init.sh` —
  generates the identity, caches it in the login Keychain, writes `recipient.txt` and the
  passphrase-encrypted `identity.age` into the vault dir. The passphrase belongs in the user's
  head or personal password manager, never in a repo or the vault dir.
- **Migrating from the old Keychain backend:** `scripts/vault-migrate.sh` (auto-discovers
  legacy records; `--dry-run` first). Non-destructive — legacy records stay until the printed
  cleanup commands are run. Every vault command refuses to touch a service whose data is still
  legacy-only and points at vault-migrate.
- **New Mac / lost Keychain:** sign in to iCloud, wait for the vault dir to sync, run
  `scripts/vault-init.sh --recover`, enter the passphrase once — the identity is re-cached and
  everything is prompt-free again. (Any vault command will also offer this unlock on the fly.)
- **First service in the vault / a brand-new service name:** `vault-edit`/`vault-import` need
  `--new-service` (or a TTY confirmation) — this guards against a typo'd `--service` silently
  creating an empty namespace.

## Multi-repo, submodules & monorepos (read before creating a scope)

A **scope belongs to the repo that owns its deploy target** — the repo holding that target's config
(`wrangler.toml`, the GitHub repo, the Appwrite/Codemagic app). Put the scope in **that repo's**
`environments/`, even when the repo is pulled into another project as a **git submodule**.

- The **umbrella/parent** repo's `environments/` covers only targets the umbrella itself deploys
  (its own `local` files, or Appwrite functions whose code lives in it). Never copy a submodule's
  `cloudflare`/`gha`/… scope into the parent — that's a duplicate in the wrong place. (A worker that
  is a submodule deploys from its **own** repo, not from the umbrella.)
- **Every repo must commit its own `environments/manifest.yaml`**, on every branch a submodule or
  deploy tracks. Without it the repo isn't self-identifying: commands run from *inside* it walk
  **up** and resolve to the parent project's manifest (wrong `repo:`/`service`). `environments/`
  (manifest + scopes + variables) is branch-agnostic tooling config — keep it identical across
  branches; don't let it land on `dev` but not `main` (a classic bug when a submodule tracks `main`).
- Resolution is by the `repo:` in a manifest (scanned under `$SECRETS_VAULT_REPOS_ROOT`), so
  `<repo>/<scope>` works from anywhere — you need **not** be inside the parent. A repo checked out
  twice (its own clone **and** a parent's `submodule/` path) yields two manifests with the same
  `repo:`; the resolver picks one — fine, since they're the same repo with the same scopes.
- All repos in one ecosystem share **one** `service` (one vault dir); each manifest just sets
  `service:`. Secrets are shared; each scope selects the subset its target needs.

**Before creating a scope:** find the repo that owns the target and check `<repo>/environments/` —
it may already have it. If the target lives in a submodule, edit the submodule's repo, not the parent.

## Conventions & safety

- Requires `age` (`brew install age`). All vault writes encrypt with the public key only; reads
  use the Keychain-cached identity (or prompt once for the recovery passphrase and re-cache).
- A scope lives in the repo that **owns its deploy target**, never in an umbrella repo that merely
  submodules it; commit each repo's `environments/manifest.yaml` so it self-identifies from any checkout.
- **Destructive writes are guarded.** Replacing/blanking an existing **non-blank** secret
  (`vault-import --force`, or a `vault-edit` that deletes/blanks/changes a value) prints a loud
  warning (key, masked old → new) and requires typing `overwrite` at the TTY; `--yes` bypasses it
  (automation — explicit opt-in). With no TTY and no `--yes`, it **aborts** rather than clobber.
  `vault-delete` requires typing `delete <service>/<stage>`. Adding keys / filling blanks is
  non-destructive and needs no confirmation.
- `vault-edit`/`vault-import` preserve comments, blank lines and key order in the stored blob.
- `print`/`vault-show` without `--mask` emit secrets — never redirect into a repo.
- `environments/` files (manifest, variables, scopes) contain **no secrets** and are committed.
  The only public-safe vault file is `recipient.txt`.
- iCloud quirks: an evicted ("dataless") vault file is downloaded automatically (bounded wait);
  conflict copies like `<stage> 2.age` are ignored by tooling — resolve manually (single-writer
  assumption).
- Apply prompts before writing to a remote target (skip with `--yes`); use `--dry-run` first.

## Onboarding a new project

To set up `environments/` for a repo that has no secret management yet — scan its existing
secrets/variables, create the manifest + scope files, and import secrets into a vault — read
[references/init-project.md](references/init-project.md). Load it only for that task.
