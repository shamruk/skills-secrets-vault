---
name: secrets-vault
description: >-
  Manage project secrets and non-secret variables across any repo/ecosystem, with the macOS
  login Keychain as the source of truth for secrets. Use when asked to view, edit, rotate, add,
  or fill in secrets/env vars; check/print/export/apply a project's environment scope; sync
  secrets to Cloudflare Workers, GitHub Actions, Appwrite, or a local .env/.dev.vars; or onboard
  a new project ("set up secrets/environments for this repo"). Triggers: secrets, env vars,
  vault, Keychain, .env/.dev.vars, "rotate the key", "set the Cloudflare/GitHub secret",
  production vs sandbox credentials; monorepo/submodule projects ("which repo owns this scope?").
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
# target: cloudflare        # cloudflare | gha | appwrite | codemagic | local
# wrangler-dir: .           # (cloudflare) dir with wrangler.toml, relative to repo
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

scripts/vault-list.sh [--service <ns>]                        # stages + key counts (no values)
scripts/vault-show.sh <stage> [--service <ns>] [--mask] [KEY …]
scripts/vault-edit.sh <stage> [--service <ns>]                # $EDITOR a stage; add/rotate/fill blanks
scripts/vault-import.sh <stage> [--service <ns>] [--force] [FILE]   # merge a dotenv file into a stage
```

`apply` routing: **cloudflare** → `wrangler secret put … --env <stage>` (secrets only; vars stay
in wrangler.toml); **gha** → `gh secret set` for secrets, `gh variable set` for variables;
**local** → merge secrets+variables into the dotenv file (other lines untouched); **appwrite** →
prints masked values to set as function variables (auto-push not wired); **codemagic** → REST API
upsert into the app's env-var group (secret → `secure:true`, variable → `secure:false`); auth via
`$CODEMAGIC_API_TOKEN` or vault/`common` `CODEMAGIC_API_TOKEN`.

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
- All repos in one ecosystem share **one** `service` (one vault); each manifest just sets `service:`.
  Secrets are shared; each scope selects the subset its target needs.

**Before creating a scope:** find the repo that owns the target and check `<repo>/environments/` —
it may already have it. If the target lives in a submodule, edit the submodule's repo, not the parent.

## Conventions & safety

- A scope lives in the repo that **owns its deploy target**, never in an umbrella repo that merely
  submodules it; commit each repo's `environments/manifest.yaml` so it self-identifies from any checkout.
- `print`/`vault-show` without `--mask` emit secrets — never redirect into a repo.
- `environments/` files (manifest, variables, scopes) contain **no secrets** and are committed.
- `security -w` hex-dumps multi-line values on read; the lib decodes transparently.
- Apply prompts before writing to a remote target (skip with `--yes`); use `--dry-run` first.

## Onboarding a new project

To set up `environments/` for a repo that has no secret management yet — scan its existing
secrets/variables, create the manifest + scope files, and import secrets into a vault — read
[references/init-project.md](references/init-project.md). Load it only for that task.
