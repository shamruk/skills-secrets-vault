---
name: secrets-vault
description: >-
  Manage project secrets and non-secret variables across any repo/ecosystem from one durable,
  cloud-synced vault. Use when asked to view, edit, rotate, add, or fill in secrets/env vars;
  check/print/export/apply a project's environment scope; sync secrets to Cloudflare Workers,
  GitHub Actions, Codemagic, Appwrite, or a local .env/.dev.vars; or onboard a new project
  ("set up secrets/environments for this repo"). Triggers: secrets, env vars, vault,
  .env/.dev.vars, "rotate the key", "set the Cloudflare/GitHub secret", production vs sandbox
  credentials; monorepo/submodule projects ("which repo owns this scope?").
---

# secrets-vault

**Secrets** live in one encrypted vault (per-user, survives losing the machine); **variables**
(non-secret) live in committed dotenv files; **scopes** declare which keys each deploy target
needs; `secrets.sh` resolves a scope and `check`/`print`/`export`/`apply`s it.

Use the commands below as the only interface. Do **not** read `scripts/` or
[references/internals.md](references/internals.md) unless a command fails unexpectedly, you are
debugging the vault itself, or you were asked to change the skill — using the vault never
requires knowing how it stores things.

## Model

- **service** — one namespace per ecosystem (e.g. `acme.dev`), shared by all its repos. Holds
  3 **stages**: `production`, `sandbox`, `common` (`common` = same value for every stage).
  The stage picks the value, so key names stay environment-neutral (no `_PROD` suffixes).
- **variables** — non-secret values committed in `environments/variables` and optional
  `environments/variables.<stage>` (plain `KEY=VALUE`).
- **manifest** — `environments/manifest.yaml`: `service:` + `repo:` (identifies the project).
- **scope** — `environments/<scope>` text file listing the keys one deploy **target** needs.

A key resolves as a **secret** (found in the vault) or a **variable** (found in a variables
file); `apply` routes each accordingly per target.

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

## One-time setup (only when a command asks for it)

These matter only on a fresh machine or brand-new vault — commands will tell you which one
they need; don't run them preemptively:

- `scripts/vault-init.sh` — first-ever vault on this machine (interactive: the user must
  choose a recovery passphrase at a real terminal — never pick or type it for them).
- `scripts/vault-init.sh --recover` — new Mac / vault exists but this machine can't unlock it
  (interactive: user enters their passphrase once; everything is prompt-free afterwards).
- `scripts/vault-migrate.sh [--dry-run]` — a command reports legacy data that needs migrating.
  Non-destructive; prints cleanup steps to run after verifying.
- A brand-new service name needs `--new-service` on `vault-edit`/`vault-import` (typo guard).

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
- All repos in one ecosystem share **one** `service`; each manifest just sets `service:`.
  Secrets are shared; each scope selects the subset its target needs.

**Before creating a scope:** find the repo that owns the target and check `<repo>/environments/` —
it may already have it. If the target lives in a submodule, edit the submodule's repo, not the parent.

## Conventions & safety

- A scope lives in the repo that **owns its deploy target**, never in an umbrella repo that merely
  submodules it; commit each repo's `environments/manifest.yaml` so it self-identifies from any checkout.
- **Destructive writes are guarded.** Replacing/blanking an existing **non-blank** secret
  (`vault-import --force`, or a `vault-edit` that deletes/blanks/changes a value) prints a loud
  warning (key, masked old → new) and requires typing `overwrite` at the TTY; `--yes` bypasses it
  (automation — explicit opt-in). With no TTY and no `--yes`, it **aborts** rather than clobber.
  `vault-delete` requires typing `delete <service>/<stage>`. Adding keys / filling blanks is
  non-destructive and needs no confirmation.
- `print`/`vault-show` without `--mask` emit secrets — never redirect into a repo, and prefer
  `--mask` whenever the values themselves aren't needed.
- `environments/` files (manifest, variables, scopes) contain **no secrets** and are committed.
- Apply prompts before writing to a remote target (skip with `--yes`); use `--dry-run` first.

## Onboarding a new project

To set up `environments/` for a repo that has no secret management yet — scan its existing
secrets/variables, create the manifest + scope files, and import secrets into the vault — read
[references/init-project.md](references/init-project.md). Load it only for that task.
