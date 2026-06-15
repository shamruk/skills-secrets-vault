---
name: secrets-vault
description: >-
  Manage project secrets and non-secret variables across any repo/ecosystem, with the macOS
  login Keychain as the source of truth for secrets. Use when asked to view, edit, rotate, add,
  or fill in secrets/env vars; check/print/export/apply a project's environment scope; sync
  secrets to Cloudflare Workers, GitHub Actions, Appwrite, or a local .env/.dev.vars; or onboard
  a new project ("set up secrets/environments for this repo"). Triggers: secrets, env vars,
  vault, Keychain, .env/.dev.vars, "rotate the key", "set the Cloudflare/GitHub secret",
  production vs sandbox credentials.
---

# secrets-vault

A small bash toolkit. **Secrets** live in the macOS Keychain; **variables** (non-secret) live in
committed dotenv files; **scopes** declare which keys each deploy target needs; the engine
resolves a scope and `check`/`print`/`export`/`apply`s it.

## Model

- **service** — a Keychain namespace per ecosystem (e.g. `lunai.care`). Holds 3 **stages**
  (`production`, `sandbox`, `common`), each a "secure note" dotenv blob of secret values.
  `common` = identical across stages. Stage is chosen by *which record* you read, so key names
  are environment-neutral.
- **variables** — non-secret values committed in `environments/variables` and optional
  `environments/variables.<stage>` (plain `KEY=VALUE`).
- **manifest** — `environments/manifest.yaml` (YAML): `service:` + `repo:` (project metadata).
- **scope** — `environments/<scope>` text file listing the keys a **target** needs.

A key resolves as a **secret** (found in a vault) or a **variable** (found in a variables file);
`apply` routes by source per target.

## Scope file format (`environments/<scope>`)

```
# target: cloudflare        # cloudflare | gha | appwrite | local
# wrangler-dir: .           # (cloudflare) dir with wrangler.toml, relative to repo
# github: ORG/REPO          # (gha) GitHub repo
# file: .dev.vars           # (local) dotenv file to render, relative to repo

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

scripts/vault-list.sh [--service <ns>]                        # stages + key counts (no values)
scripts/vault-show.sh <stage> [--service <ns>] [--mask] [KEY …]
scripts/vault-edit.sh <stage> [--service <ns>]                # $EDITOR a stage; add/rotate/fill blanks
scripts/vault-import.sh <stage> [--service <ns>] [--force] [FILE]   # merge a dotenv file into a stage
```

`apply` routing: **cloudflare** → `wrangler secret put … --env <stage>` (secrets only; vars stay
in wrangler.toml); **gha** → `gh secret set` for secrets, `gh variable set` for variables;
**local** → merge secrets+variables into the dotenv file (other lines untouched); **appwrite** →
prints masked values to set as function variables (auto-push not wired).

## Conventions & safety

- `print`/`vault-show` without `--mask` emit secrets — never redirect into a repo.
- `environments/` files (manifest, variables, scopes) contain **no secrets** and are committed.
- `security -w` hex-dumps multi-line values on read; the lib decodes transparently.
- Apply prompts before writing to a remote target (skip with `--yes`); use `--dry-run` first.

## Onboarding a new project

To set up `environments/` for a repo that has no secret management yet — scan its existing
secrets/variables, create the manifest + scope files, and import secrets into a vault — read
[references/init-project.md](references/init-project.md). Load it only for that task.
