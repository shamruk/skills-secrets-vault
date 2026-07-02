#!/usr/bin/env bash
# Shared helpers for the secrets-vault skill (project-agnostic).
#
# Storage model:
#   secrets   -> age-encrypted files in an iCloud Drive folder ($VAULT_DIR), so the vault
#                survives losing the machine. Per ecosystem a "service" directory holds 3
#                encrypted stage files: production.age | sandbox.age | common.age.
#                plaintext = dotenv blob (KEY=VALUE), env-neutral key names.
#   keys      -> one X25519 age identity for the whole vault:
#                  * plaintext identity cached in the macOS login Keychain
#                    (item: -s secrets-vault -a age-identity) for prompt-free daily use
#                  * $VAULT_DIR/identity.age = the identity encrypted with a passphrase
#                    (age -p) — disaster-recovery copy, syncs via iCloud
#                  * $VAULT_DIR/recipient.txt = the public key; all writes encrypt with
#                    this, so writing never needs the secret identity
#   variables -> committed dotenv files in a project's environments/: `variables` (base) +
#                optional `variables.<stage>` overrides. Plain KEY=VALUE (not YAML).
#   manifest  -> environments/manifest.yaml (YAML): project metadata `service:` + `repo:`.
#   scopes    -> environments/<scope> text files: which keys a target needs (see secrets.sh).
#
# Source this file; do not execute it.

set -euo pipefail

KC_KIND="secrets-vault"            # legacy Keychain record kind (pre-age storage; vault-migrate.sh)
KC_STAGES=(production sandbox common)
KC_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
YAML2JSON="$KC_HERE/yaml2json"

# Vault location (any dir works; iCloud Drive gives off-machine durability). Override via env.
VAULT_DIR="${SECRETS_VAULT_DIR:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/secrets-vault}"
VAULT_KC_SERVICE="secrets-vault"   # Keychain item caching the plaintext age identity
VAULT_KC_ACCOUNT="${SECRETS_VAULT_KC_ACCOUNT:-age-identity}"   # override only for tests
VAULT_KC_KIND="secrets-vault-identity"

# Root to scan for projects (each declares itself via environments/manifest.yaml). Override via env.
SECRETS_VAULT_REPOS_ROOT="${SECRETS_VAULT_REPOS_ROOT:-$HOME/Projects}"

# ---- legacy keychain access (read-only: identity cache + vault-migrate.sh) ----

kc_put() {
  security add-generic-password -U -D "$KC_KIND" -s "$1" -a "$2" -j "secrets-vault" -w "$3"
}

# kc_get <service> <account>  -> blob on stdout. `security -w` hex-dumps multi-line values; decode.
kc_get() {
  local raw
  raw="$(security find-generic-password -s "$1" -a "$2" -w 2>/dev/null)" || return 1
  if [[ "$raw" =~ ^[0-9a-fA-F]+$ ]] && (( ${#raw} % 2 == 0 )); then
    printf '%s' "$raw" | xxd -r -p
  else
    printf '%s' "$raw"
  fi
}

kc_exists() { security find-generic-password -s "$1" -a "$2" >/dev/null 2>&1; }
kc_delete() { security delete-generic-password -s "$1" -a "$2" >/dev/null 2>&1; }

# ---- age identity ------------------------------------------------------------

vault_require_age() {
  command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1 && return 0
  echo "age not found — install with: brew install age" >&2
  return 1
}

_kc_identity_get() { kc_get "$VAULT_KC_SERVICE" "$VAULT_KC_ACCOUNT"; }

# Cache the identity in the login Keychain. Hex-encoded and fed to `security -i` on stdin
# so the secret never appears in any process argv.
_kc_identity_put() {
  local hex
  hex="$(printf '%s' "$1" | xxd -p | tr -d '\n')"
  printf 'add-generic-password -U -D "%s" -s "%s" -a "%s" -j "secrets-vault" -w %s\n' \
    "$VAULT_KC_KIND" "$VAULT_KC_SERVICE" "$VAULT_KC_ACCOUNT" "$hex" | security -i >/dev/null
}

# identity_load -> the AGE-SECRET-KEY-1… line on stdout.
# Order: $SECRETS_VAULT_IDENTITY_FILE (tests/CI) | Keychain cache | identity.age (passphrase
# prompt, then re-cache) | error. Memoized per process.
_VAULT_IDENTITY=""
identity_load() {
  if [[ -n "${_VAULT_IDENTITY:-}" ]]; then printf '%s\n' "$_VAULT_IDENTITY"; return 0; fi
  local id=""
  if [[ -n "${SECRETS_VAULT_IDENTITY_FILE:-}" ]]; then
    id="$(grep -m1 '^AGE-SECRET-KEY-1' "$SECRETS_VAULT_IDENTITY_FILE")" \
      || { echo "no age identity in \$SECRETS_VAULT_IDENTITY_FILE" >&2; return 1; }
  elif id="$(_kc_identity_get)" && [[ -n "$id" ]]; then
    :
  elif _vault_materialize "$VAULT_DIR/identity.age" 2>/dev/null; then
    echo "vault identity not in Keychain — unlocking recovery copy $VAULT_DIR/identity.age" >&2
    id="$(age -d "$VAULT_DIR/identity.age" | grep -m1 '^AGE-SECRET-KEY-1')" \
      || { echo "could not decrypt identity.age (wrong passphrase?)" >&2; return 1; }
    _kc_identity_put "$id"
    echo "identity cached in login Keychain — no passphrase needed next time" >&2
  else
    echo "no vault identity: run vault-init.sh (new vault) — or, on a new Mac, wait for" >&2
    echo "iCloud Drive to sync $VAULT_DIR and run vault-init.sh --recover" >&2
    return 1
  fi
  _VAULT_IDENTITY="$id"
  printf '%s\n' "$id"
}

# _recipient_file -> path to the public-key file (regenerated from the identity if missing)
_recipient_file() {
  local rf="$VAULT_DIR/recipient.txt" id
  if ! _vault_materialize "$rf" 2>/dev/null; then
    id="$(identity_load)" || return 1
    mkdir -p "$VAULT_DIR"
    printf '%s\n' "$id" | age-keygen -y >"$rf.tmp.$$" && mv "$rf.tmp.$$" "$rf"
  fi
  printf '%s' "$rf"
}

# ---- age vault storage -------------------------------------------------------

# _vault_materialize <path>  -> 0 if the file exists (downloading a dataless iCloud
# placeholder if needed), 1 if it doesn't.
_vault_materialize() {
  local f="$1" ph i=0
  [[ -f "$f" ]] && return 0
  ph="$(dirname "$f")/.$(basename "$f").icloud"
  [[ -f "$ph" ]] || return 1
  command -v brctl >/dev/null 2>&1 && brctl download "$f" >/dev/null 2>&1 || true
  while (( i < 40 )); do
    [[ -f "$f" ]] && return 0
    sleep 0.5; i=$((i+1))
  done
  echo "vault file is in iCloud but not downloading: $f — check network/iCloud Drive status" >&2
  return 1
}

# vault_get <service> <stage>  -> decrypted dotenv blob on stdout; 1 if the stage is absent
vault_get() {
  local f="$VAULT_DIR/$1/$2.age" id
  _vault_materialize "$f" || return 1
  id="$(identity_load)" || return 1
  age -d -i <(printf '%s\n' "$id") "$f"
}

# vault_put <service> <stage> <blob>  — encrypt to the vault (atomic tmp+mv; needs only the
# public recipient). Creating a brand-new service requires VAULT_ALLOW_NEW_SERVICE=1 (see
# vault_ensure_service) to guard against typo'd --service silently creating a namespace.
vault_put() {
  local svc="$1" stage="$2" blob="$3" dir rf tmp
  dir="$VAULT_DIR/$svc"
  if [[ ! -d "$dir" && "${VAULT_ALLOW_NEW_SERVICE:-0}" != 1 ]]; then
    echo "service '$svc' does not exist in the vault ($VAULT_DIR) — pass --new-service to create it" >&2
    return 1
  fi
  rf="$(_recipient_file)" || return 1
  mkdir -p "$dir"
  tmp="$dir/.$stage.age.tmp.$$"
  printf '%s\n' "$blob" | age -e -R "$rf" -o "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp"
  mv -f "$tmp" "$dir/$stage.age"
}

vault_exists() { [[ -f "$VAULT_DIR/$1/$2.age" ]]; }
vault_delete_stage() { rm -f "$VAULT_DIR/$1/$2.age"; }

# vault_services -> service names (one per line); skips key files and iCloud conflict copies
vault_services() {
  local d b
  [[ -d "$VAULT_DIR" ]] || return 0
  for d in "$VAULT_DIR"/*/; do
    [[ -d "$d" ]] || continue
    b="$(basename "$d")"
    case "$b" in .*|*' '[0-9]) continue ;; esac
    printf '%s\n' "$b"
  done
}

# vault_check_migration <service> — refuse to operate on a service whose data still lives
# only in the legacy Keychain storage (pre-age). Call after resolving the service.
vault_check_migration() {
  local svc="$1" st
  for st in "${KC_STAGES[@]}"; do vault_exists "$svc" "$st" && return 0; done
  for st in "${KC_STAGES[@]}"; do
    if kc_exists "$svc" "$st"; then
      echo "legacy Keychain data found for '$svc' but no age vault — run vault-migrate.sh --service '$svc' first" >&2
      return 1
    fi
  done
  return 0
}

# vault_ensure_service <service> <allow_new:0|1> <yes:0|1> — typo guard: creating a new
# service namespace needs --new-service / --yes / a TTY confirmation.
vault_ensure_service() {
  local svc="$1" allow="${2:-0}" yes="${3:-0}" ans
  [[ -d "$VAULT_DIR/$svc" ]] && return 0
  if [[ "$allow" == 1 || "$yes" == 1 ]]; then VAULT_ALLOW_NEW_SERVICE=1; return 0; fi
  echo "service '$svc' does not exist in the vault ($VAULT_DIR)" >&2
  ans=""
  { read -r -p "Create new service '$svc'? [y/N] " ans </dev/tty; } 2>/dev/null \
    || { echo "aborted: not a TTY — pass --new-service to create a new service namespace" >&2; return 1; }
  [[ "$ans" == [yY]* ]] || { echo "aborted" >&2; return 1; }
  VAULT_ALLOW_NEW_SERVICE=1
}

# ---- dotenv blob helpers -----------------------------------------------------

# de_keys <blob>  -> KEY names (one per line), skips comments/blanks
de_keys() {
  awk -F= '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} {sub(/[[:space:]]*=.*/,"",$0); gsub(/[[:space:]]/,"",$0); print}' <<<"${1:-}"
}

# de_get <blob> <key>  -> value (everything after first '='); empty if absent
de_get() {
  awk -v k="$2" -F= '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
    { key=$1; gsub(/[[:space:]]/,"",key);
      if (key==k){ sub(/^[^=]*=/,"",$0); print $0; exit } }' <<<"${1:-}"
}

# here-string (not a pipe) so de_keys can't SIGPIPE-fail under `set -o pipefail`
de_has()   { grep -qxF "$2" <<<"$(de_keys "${1:-}")"; }
de_count() { de_keys "${1:-}" | grep -c . || true; }

# ---- manifest (YAML) + variables (dotenv) ------------------------------------

# mf_get <dir> <jq-filter>  -> value from environments/manifest.yaml (empty if absent)
mf_get() {
  local mf="$1/environments/manifest.yaml"
  [[ -f "$mf" ]] || return 0
  "$YAML2JSON" "$mf" | jq -r "$2 // empty"
}
service_for() { mf_get "$1" '.service'; }     # service_for <dir>

# var_get <dir> <stage> <key>  -> variables.<stage> then variables (dotenv)
var_get() {
  local dir="$1" stage="$2" key="$3" v
  if [[ -f "$dir/environments/variables.$stage" ]]; then
    v="$(de_get "$(cat "$dir/environments/variables.$stage")" "$key")"
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
  fi
  if [[ -f "$dir/environments/variables" ]]; then
    de_get "$(cat "$dir/environments/variables")" "$key"
  fi
  return 0   # absence of a variables file must not abort callers under `set -e`
}

# var_has <dir> <stage> <key>  -> exit 0 if declared as a variable
var_has() {
  local dir="$1" stage="$2" key="$3"
  { [[ -f "$dir/environments/variables.$stage" ]] && de_has "$(cat "$dir/environments/variables.$stage")" "$key"; } && return 0
  [[ -f "$dir/environments/variables" ]] && de_has "$(cat "$dir/environments/variables")" "$key"
}

# ---- project resolution (no central registry) --------------------------------

# _scan_manifests  -> every environments/manifest.yaml under the repos root (bounded + pruned)
_scan_manifests() {
  find "$SECRETS_VAULT_REPOS_ROOT" -maxdepth 8 \
    \( -name node_modules -o -name .git -o -name build -o -name .dart_tool \
       -o -name Pods -o -name DerivedData -o -name .venv -o -name venv \
       -o -name dist -o -name target -o -name vendor -o -name .next -o -name .gradle \) -prune -o \
    -type f -path '*/environments/manifest.yaml' -print 2>/dev/null
}

# A repo→dir index is cached (the scan is slow on a big tree). It self-heals on a miss.
_cache_file() { printf '%s/repo-index' "${SECRETS_VAULT_CACHE:-$HOME/.cache/secrets-vault}"; }
_rebuild_cache() {
  local cf mf r d; cf="$(_cache_file)"; mkdir -p "$(dirname "$cf")"; : >"$cf.tmp"
  while IFS= read -r mf; do
    [[ -z "$mf" ]] && continue
    r="$("$YAML2JSON" "$mf" 2>/dev/null | jq -r '.repo // empty')"; [[ -z "$r" ]] && continue
    d="$(cd "$(dirname "$mf")/.." && pwd)"
    printf '%s\t%s\n' "$r" "$d" >>"$cf.tmp"
  done < <(_scan_manifests)
  mv "$cf.tmp" "$cf"
}
_cache_lookup() { local cf; cf="$(_cache_file)"; [[ -f "$cf" ]] && awk -F'\t' -v r="$1" '$1==r{print $2; exit}' "$cf"; }
_dir_is_repo() { [[ -f "$1/environments/manifest.yaml" ]] && \
  [[ "$("$YAML2JSON" "$1/environments/manifest.yaml" 2>/dev/null | jq -r '.repo // empty')" == "$2" ]]; }

# repo_dir <repo>  -> absolute project dir (cache first; rescan on miss). Set SECRETS_VAULT_NOCACHE=1 to bypass.
repo_dir() {
  local want="$1" d
  if [[ -z "${SECRETS_VAULT_NOCACHE:-}" ]]; then
    d="$(_cache_lookup "$want")"
    if [[ -n "$d" ]] && _dir_is_repo "$d" "$want"; then printf '%s' "$d"; return 0; fi
  fi
  _rebuild_cache
  d="$(_cache_lookup "$want")"
  [[ -n "$d" ]] && { printf '%s' "$d"; return 0; }
  echo "repo not found: no environments/manifest.yaml with repo: '$want' under $SECRETS_VAULT_REPOS_ROOT" >&2
  return 1
}

# find_project_dir [start]  -> walk up from cwd to the project root (has environments/manifest.yaml)
find_project_dir() {
  local d; d="$(cd "${1:-$PWD}" && pwd)"
  while [[ "$d" != "/" ]]; do
    [[ -f "$d/environments/manifest.yaml" ]] && { printf '%s' "$d"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

# pick_service [--service X already parsed into $1]  -> service from arg | env | cwd project
# Usage: SERVICE="$(pick_service "${SERVICE_FLAG:-}")"
pick_service() {
  if [[ -n "${1:-}" ]]; then printf '%s' "$1"; return 0; fi
  if [[ -n "${SECRETS_VAULT_SERVICE:-}" ]]; then printf '%s' "$SECRETS_VAULT_SERVICE"; return 0; fi
  local d; d="$(find_project_dir 2>/dev/null)" && service_for "$d"
}
