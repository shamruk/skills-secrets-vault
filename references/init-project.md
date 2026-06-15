# Onboarding a new project into secrets-vault

Goal: give a repo an `environments/` folder (manifest + scopes + variables) and load its secrets
into a Keychain vault, so `secrets.sh` can check/print/apply them. Do this once per project.

## 1. Decide the ecosystem `service`
Secrets are grouped by a Keychain **service** namespace shared by related projects (e.g.
`lunai.care`). Reuse the existing one if this repo belongs to a known ecosystem; otherwise pick a
new stable name. The three stages are always `production`, `sandbox`, `common`.

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
- **Secret** → goes in the Keychain vault (API keys, tokens, passwords, webhook secrets).
- **Variable** (non-secret) → committed dotenv files (URLs, project IDs, site IDs, bundle IDs,
  publishable keys). When unsure, treat as a secret.

## 4. Normalize key names (environment-neutral)
The stage is the vault record, so drop stage infixes: `PADDLE_SANDBOX_ADMIN_TOKEN` /
`PADDLE_PROD_ADMIN_TOKEN` → one `PADDLE_ADMIN_TOKEN` (different value per stage). If the same key
name means *different* secrets in two projects, namespace it (`WORKERS_OPENROUTER_API_KEY`) and
remap in the scope.

## 5. Create `environments/`
```
environments/
  manifest.yaml          # service: <ns>\n repo: <github-repo-name>
  variables              # non-secret, stage-agnostic   (optional)
  variables.production   # per-stage non-secret overrides (optional)
  variables.sandbox
  <scope> …              # one per target
```
Scope file (see SKILL.md for full syntax) — list every key the target needs; use `DEST = SRC`
to rename and `SRC@stage` to pin a stage:
```
# target: cloudflare
# wrangler-dir: .
STRIPE_SECRET_KEY
OPENROUTER_API_KEY = WORKERS_OPENROUTER_API_KEY
```
Pick `repo:` to match how you'll address it: `secrets.sh … <repo>/<scope>`.

## 6. Load secrets into the vault
Per stage, assemble a temporary dotenv file of the **secret** values (env-neutral names) and:
```bash
scripts/vault-import.sh sandbox    --service <ns> /path/to/sandbox-secrets.env
scripts/vault-import.sh production  --service <ns> /path/to/prod-secrets.env   # often blanks to fill later
```
`vault-import` is conflict-aware (won't clobber a differing existing value without `--force`) and
never prints values. Put env-agnostic secrets (same in all stages) into `common`. Use
`vault-edit.sh <stage> --service <ns>` to fill blanks or rotate by hand. **Delete the temp files
afterward** (`rm -P`); they hold plaintext.

## 7. Verify
```bash
scripts/vault-list.sh --service <ns>
scripts/secrets.sh check <repo>/<scope> --stage sandbox     # every key ok or BLANK, tagged secret|variable
scripts/secrets.sh apply <repo>/<scope> --stage sandbox --dry-run
```

## 8. Hygiene
- Add real secret files (`.env`, `.dev.vars`) to `.gitignore`. If any were committed, untrack
  (`git rm --cached`), gitignore, and **rotate** the exposed values, then update the vault.
- `environments/` (manifest, variables, scopes) is non-secret and should be committed.
