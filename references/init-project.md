# Onboarding a new project into secrets-vault

Goal: give a repo an `environments/` folder (manifest + scopes + variables) and load its secrets
into the age vault, so `secrets.sh` can check/print/apply them. Do this once per project.

Prerequisite (once per machine): `scripts/vault-init.sh` — skip if the vault already works;
any command will say what's missing otherwise (see SKILL.md "One-time setup").

## 1. Decide the ecosystem `service`
Secrets are grouped by a **service** namespace — a directory in the vault — shared by related
projects (e.g. `acme.dev`). Check `scripts/vault-list.sh --all` for existing services and reuse
the ecosystem's one if this repo belongs to it; otherwise pick a new stable name. The three
stages are always `production`, `sandbox`, `common`.

## 2. Discover what the project uses
Scan, from the repo root:
- **Secret files:** `**/.env`, `**/.dev.vars`, `**/*.env` (gitignored ones hold real values).
- **Cloudflare:** `wrangler.toml` — `[vars]` are non-secret **variables**; the `# secrets:`
  comment block / `wrangler secret list` are **secrets**; `interface Env` in `src/types/env.ts`.
- **GitHub Actions:** `.github/workflows/*.yml` — `secrets.*` and `vars.*` references.
- **Appwrite / Node:** `process.env.*` / `Bun.env.*` usage in functions.
- **Code-embedded config:** publishable/client keys in source (often non-secret).

Helpful sweeps:
```bash
grep -rhoE '(process\.env|Bun\.env)\.[A-Z_]+' . | sed 's/.*\.//' | sort -u
grep -rnE 'secrets\.|vars\.' .github/workflows 2>/dev/null
```

## 3. Classify every value: secret vs variable
- **Secret** → goes in the vault (API keys, tokens, passwords, webhook secrets).
- **Variable** (non-secret) → committed dotenv files (URLs, project IDs, site IDs, bundle IDs,
  publishable keys). When unsure, treat as a secret.

Both kinds are listed in a scope by key name; the engine tags each by where it resolves
(vault = **secret**, `variables` file = **variable**) and routes it per target (e.g. gha →
`gh secret set` vs `gh variable set`). Variables are *only ever committed files* — never imported
into the vault.

## 4. Normalize key names (environment-neutral)
The stage is the vault record, so drop stage infixes: `PADDLE_SANDBOX_ADMIN_TOKEN` /
`PADDLE_PROD_ADMIN_TOKEN` → one `PADDLE_ADMIN_TOKEN` (different value per stage). If the same key
name means *different* secrets in two projects, namespace it (`WORKERS_OPENROUTER_API_KEY`) and
remap in the scope.

## 5. Create `environments/`
```
environments/
  manifest.yaml          # YAML — service: <ns> + repo: <name>  (metadata only)
  variables              # dotenv — non-secret, stage-agnostic            (optional)
  variables.production   # dotenv — per-stage overrides (win over `variables`)  (optional)
  variables.sandbox
  <scope> …              # one text file per target
```
Write variable values straight into the dotenv files (no import step), e.g.
`echo 'SUPABASE_PROJECT_ID=abcdefghijklmnopqrst' > environments/variables.sandbox`.

Scope file (full syntax in SKILL.md) — list every key the target needs, secrets and variables
alike; `DEST = SRC` renames, `SRC@stage` pins a stage:
```
# target: gha               # cloudflare → '# wrangler-dir:' · gha → '# github: ORG/REPO' · local → '# file: <path>'
# github: ORG/REPO
SUPABASE_ACCESS_TOKEN                              # secret  (from a vault)
PROD_DB_PASSWORD = DB_PASSWORD@production          # secret  (cross-stage)
PROD_PROJECT_ID  = SUPABASE_PROJECT_ID@production  # variable (from variables.production)
```
Pick `repo:` to match how you'll address it: `secrets.sh … <repo>/<scope>`.

## 6. Load secrets into the vault
Per stage, assemble a temporary dotenv file of the **secret** values (env-neutral names) and:
```bash
scripts/vault-import.sh sandbox    --service <ns> --new-service /path/to/sandbox-secrets.env  # --new-service only for a brand-new service
scripts/vault-import.sh production  --service <ns> /path/to/prod-secrets.env   # often blanks to fill later
scripts/vault-import.sh common     --service <ns> /path/to/shared-secrets.env  # values identical across stages
```
`vault-import` is conflict-aware (won't clobber a differing existing value without `--force`) and
never prints values. Put env-agnostic secrets (same in all stages) into `common` — a scope reads
`<stage>` then falls back to `common`, so list the key once and it resolves everywhere. Use
`vault-edit.sh <stage> --service <ns>` to fill blanks or rotate by hand. **Delete the temp files
afterward** (`rm -f`, or `rm -P` to overwrite first); they hold plaintext.

## 7. Verify
```bash
scripts/vault-list.sh --service <ns>
scripts/secrets.sh check <repo>/<scope> --stage sandbox     # every key ok or BLANK, tagged secret|variable
scripts/secrets.sh apply <repo>/<scope> --stage sandbox --dry-run
```
`<repo>` is resolved by scanning `SECRETS_VAULT_REPOS_ROOT` (default `~/Projects`) for a
`manifest.yaml` with that `repo:`; the index is cached and rebuilt on a miss, so a brand-new
project is picked up automatically (first lookup is slower).

## 8. Record it in the repo's `CLAUDE.md`
So future Claude sessions (and teammates) don't hand-roll `.env` files or invent key names, add a
short **Secrets & environment variables** section to the repo's `CLAUDE.md` (create the file if it
has none; update the section if one already exists). State that the env is vault-managed and pin the
specifics — service, repo, and the scopes — so the skill loads with the right local context:

```md
## Secrets & environment variables
Managed by the **secrets-vault** skill — do not hand-edit `.env`/`.dev.vars`, invent key names, or
rotate by hand. Config lives in `environments/` (service `acme.dev`, repo `my-worker`): secrets
resolve from the age vault, non-secret variables from the committed `variables` files.
Scopes (deploy targets): `cloudflare`, `gha`. Use the skill to check/print/apply a scope or to
add/rotate a secret — `secrets.sh check|apply my-worker/<scope> --stage <production|sandbox>`,
`vault-edit.sh <stage> --service acme.dev`.
```

Fill in the real service/repo/scope names (drop targets this repo doesn't have). If this repo is
used as a **git submodule** elsewhere, this note belongs in **its own** `CLAUDE.md`, not the
parent's — same rule as `environments/` (see SKILL.md "Multi-repo, submodules & monorepos").

## 9. Hygiene
- Add real secret files (`.env`, `.dev.vars`) to `.gitignore`. If any were committed, untrack
  (`git rm --cached`), gitignore, and **rotate** the exposed values, then update the vault.
- `environments/` (manifest, variables, scopes) is non-secret and should be committed.
- If this repo is used as a **git submodule** elsewhere, its `environments/` (especially
  `manifest.yaml`) belongs in **this** repo — not the parent — and must be committed on every branch
  the submodule/deploy tracks (e.g. both `main` and `dev`), or a checkout from inside the submodule
  resolves to the parent project's manifest. See SKILL.md "Multi-repo, submodules & monorepos".
