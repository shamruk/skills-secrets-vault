#!/usr/bin/env bash
# Shared helpers for the secrets-vault skill (project-agnostic).
#
# Storage model:
#   secrets   -> macOS login Keychain. Per ecosystem a "service" namespace holds 3
#                generic-password "secure note" records (stages): production | sandbox | common.
#                value = dotenv blob (KEY=VALUE), env-neutral key names. Stage chosen by record.
#   variables -> committed dotenv files in a project's environments/: `variables` (base) +
#                optional `variables.<stage>` overrides. Plain KEY=VALUE (not YAML).
#   manifest  -> environments/manifest.yaml (YAML): project metadata `service:` + `repo:`.
#   scopes    -> environments/<scope> text files: which keys a target needs (see secrets.sh).
#
# Source this file; do not execute it.

set -euo pipefail

KC_KIND="secrets-vault"
KC_STAGES=(production sandbox common)
KC_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
YAML2JSON="$KC_HERE/yaml2json"

# Root to scan for projects (each declares itself via environments/manifest.yaml). Override via env.
SECRETS_VAULT_REPOS_ROOT="${SECRETS_VAULT_REPOS_ROOT:-$HOME/Projects}"

# ---- raw keychain access (service-scoped) ------------------------------------

# kc_put <service> <account> <blob>   (idempotent; -U updates in place)
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

vault_get() { kc_get "$1" "$2"; }            # vault_get <service> <stage>
vault_put() { kc_put "$1" "$2" "$3"; }       # vault_put <service> <stage> <blob>

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
