#!/usr/bin/env bash
# Resolve a project's scope (environments/<scope>) against its vault (secrets) and
# variables files, then check / print / export / apply.
#
# Usage:
#   secrets.sh <action> <repo>/<scope> --stage <stage> [options]
#
# actions:
#   check    report each key as ok / blank, tagged secret|variable (default; no side effects)
#   print    KEY=VALUE to stdout            (add --mask to redact)
#   export   export KEY=VALUE (for: eval "$(secrets.sh export …)")
#   apply    push to the scope's target (cloudflare | gha | appwrite | codemagic | local)
#
# options:
#   --stage <production|sandbox>   stage to read (vault + variables.<stage>); falls back to common
#   --mask                         redact values in print
#   --dry-run                      apply: show what would happen, change nothing
#   --yes                          apply: skip the confirmation prompt
#
# Keys resolve as SECRET (found in a vault) or VARIABLE (found in environments/variables[.stage]).
# apply routes by source: gha -> `gh secret set` vs `gh variable set`; local -> dotenv lines;
# appwrite -> function variables (printed; manual); cloudflare -> secrets only;
# codemagic -> REST API env-var group (secret=secure, variable=plain; auth via
#              $CODEMAGIC_API_TOKEN or vault/common CODEMAGIC_API_TOKEN).

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/kc-lib.sh"

[[ $# -ge 2 ]] || { sed -n '2,30p' "$0"; exit 2; }
ACTION="$1"; REF="$2"; shift 2
REPO="${REF%%/*}"; SCOPE="${REF#*/}"
STAGE=""; MASK=0; DRY=0; YES=0
while [[ $# -gt 0 ]]; do case "$1" in
  --stage) STAGE="$2"; shift 2 ;;
  --mask)  MASK=1; shift ;;
  --dry-run) DRY=1; shift ;;
  --yes)   YES=1; shift ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac; done

case "$ACTION" in check|print|export|apply) ;; *) echo "unknown action: $ACTION" >&2; exit 2 ;; esac

DIR="$(repo_dir "$REPO")" || exit 1
SERVICE="$(service_for "$DIR")"
[[ -n "$SERVICE" ]] || { echo "$DIR/environments/manifest.yaml missing 'service:'" >&2; exit 1; }
scope_file="$DIR/environments/$SCOPE"
[[ -f "$scope_file" ]] || { echo "no scope file: $scope_file" >&2; exit 1; }

# ---- parse scope directives + key lines ----
TARGET=""; WRANGLER_DIR="."; WRANGLER_ENV=""; GHA_REPO=""; FILE_REL=""; CM_APP_ID=""; CM_APP_NAME=""; CM_GROUP=""
KEYS=()   # entries: "dest<TAB>src<TAB>stage"
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
while IFS= read -r raw || [[ -n "$raw" ]]; do
  line="$(trim "$raw")"; [[ -z "$line" ]] && continue
  if [[ "$line" == \#* ]]; then
    d="$(trim "${line#\#}")"
    d="$(trim "${d%%#*}")"   # strip an inline comment after the directive value (e.g. `# target: x  # note`)
    case "$d" in
      target:*)       TARGET="$(trim "${d#target:}")" ;;
      wrangler-dir:*) WRANGLER_DIR="$(trim "${d#wrangler-dir:}")" ;;
      wrangler-env:*) WRANGLER_ENV="$(trim "${d#wrangler-env:}")" ;;
      github:*)       GHA_REPO="$(trim "${d#github:}")" ;;
      repo:*)         GHA_REPO="$(trim "${d#repo:}")" ;;   # legacy alias
      file:*)         FILE_REL="$(trim "${d#file:}")" ;;
      app-id:*)       CM_APP_ID="$(trim "${d#app-id:}")" ;;
      app-name:*)     CM_APP_NAME="$(trim "${d#app-name:}")" ;;
      group:*)        CM_GROUP="$(trim "${d#group:}")" ;;
    esac
    continue
  fi
  line="$(trim "${line%%#*}")"; [[ -z "$line" ]] && continue
  if [[ "$line" == *=* ]]; then dest="$(trim "${line%%=*}")"; rest="$(trim "${line#*=}")"
  else dest="$line"; rest="$line"; fi
  if [[ "$rest" == *@* ]]; then src="$(trim "${rest%@*}")"; st="$(trim "${rest##*@}")"; else src="$rest"; st="$STAGE"; fi
  KEYS+=("$dest"$'\t'"$src"$'\t'"$st")
done < "$scope_file"

[[ -n "$TARGET" ]] || { echo "scope $scope_file missing '# target:' directive" >&2; exit 1; }
if [[ -z "$STAGE" ]]; then
  for e in "${KEYS[@]}"; do [[ -z "${e##*$'\t'}" ]] && { echo "--stage required for $REF" >&2; exit 2; }; done
fi

# ---- load this service's vaults (once) ----
PROD="$(vault_get "$SERVICE" production 2>/dev/null || true)"
SAND="$(vault_get "$SERVICE" sandbox  2>/dev/null || true)"
COMMON="$(vault_get "$SERVICE" common 2>/dev/null || true)"
blob_for() { case "$1" in production) printf '%s' "$PROD";; sandbox) printf '%s' "$SAND";; common) printf '%s' "$COMMON";; *) printf '';; esac; }

# source_of <src> <stage> -> secret | variable | (empty)
source_of() {
  if de_has "$(blob_for "$2")" "$1" || de_has "$COMMON" "$1"; then echo secret
  elif var_has "$DIR" "$2" "$1"; then echo variable
  else echo ""; fi
}
# resolve <src> <stage> -> value (secret wins by presence, then variable)
resolve() {
  if de_has "$(blob_for "$2")" "$1"; then de_get "$(blob_for "$2")" "$1"; return; fi
  if de_has "$COMMON" "$1"; then de_get "$COMMON" "$1"; return; fi
  var_get "$DIR" "$2" "$1"
}

mask() { local v="$1"; [[ -z "$v" ]] && { printf '(blank)'; return; }
  (( ${#v} <= 4 )) && { printf '****'; return; }; printf '%s…(%d)' "${v:0:2}" "${#v}"; }
confirm() { [[ "$YES" == 1 ]] && return 0; local a; read -r -p "$1 [y/N] " a </dev/tty || return 1; [[ "$a" == [yY]* ]]; }

# ---- actions ----
case "$ACTION" in
check)
  printf '%-26s %-26s %-10s %-9s %s\n' DEST SRC STAGE SOURCE STATUS
  miss=0
  for e in "${KEYS[@]}"; do IFS=$'\t' read -r dest src st <<<"$e"
    src_kind="$(source_of "$src" "$st")"; v="$(resolve "$src" "$st")"
    if [[ -n "$v" ]]; then s=ok; else s=BLANK; ((miss++)) || true; fi
    printf '%-26s %-26s %-10s %-9s %s\n' "$dest" "$src" "$st" "${src_kind:-?}" "$s"
  done
  echo; echo "service=$SERVICE  target=$TARGET  keys=${#KEYS[@]}  blank=$miss"
  ;;

print|export)
  for e in "${KEYS[@]}"; do IFS=$'\t' read -r dest src st <<<"$e"
    v="$(resolve "$src" "$st")"
    [[ -z "$v" ]] && { echo "# $dest is BLANK (skipped)" >&2; continue; }
    if [[ "$ACTION" == export ]]; then printf 'export %s=%q\n' "$dest" "$v"
    elif [[ "$MASK" == 1 ]]; then printf '%s=%s\n' "$dest" "$(mask "$v")"
    else printf '%s=%s\n' "$dest" "$v"; fi
  done
  ;;

apply)
  case "$TARGET" in
  cloudflare)
    wdir="$DIR/$WRANGLER_DIR"
    [[ -f "$wdir/wrangler.toml" || -f "$wdir/wrangler.jsonc" || -f "$wdir/wrangler.json" ]] \
      || { echo "no wrangler config (.toml/.jsonc/.json) in $wdir" >&2; exit 1; }
    [[ -n "$STAGE" ]] || { echo "--stage required" >&2; exit 2; }
    # --env selects a wrangler *named environment* (a separate Worker), not the vault stage.
    # Default: --env <stage> (per-stage named envs, e.g. separate prod/sandbox Workers).
    # `# wrangler-env: none` omits --env for a single top-level Worker; `# wrangler-env: <name>`
    # pins an explicit env name. (empty-array exprs below are guarded for bash 3.2 / set -u.)
    case "${WRANGLER_ENV:-}" in
      none) envflag=();                      envlabel="(top-level)" ;;
      "")   envflag=(--env "$STAGE");         envlabel="$STAGE" ;;
      *)    envflag=(--env "$WRANGLER_ENV");  envlabel="$WRANGLER_ENV" ;;
    esac
    flagshow="${envflag[*]+${envflag[*]}}"
    echo "cloudflare: $REPO  env=$envlabel  dir=$wdir"
    confirm "Apply secrets to Cloudflare ($envlabel)?" || { echo aborted; exit 1; }
    for e in "${KEYS[@]}"; do IFS=$'\t' read -r dest src st <<<"$e"
      [[ "$(source_of "$src" "$st")" == secret ]] || { echo "  skip $dest (variable — set in wrangler config [vars])"; continue; }
      v="$(resolve "$src" "$st")"; [[ -z "$v" ]] && { echo "  skip $dest (blank)"; continue; }
      if [[ "$DRY" == 1 ]]; then echo "  would: wrangler secret put $dest${flagshow:+ $flagshow}"
      else ( cd "$wdir" && printf '%s' "$v" | npx wrangler secret put "$dest" "${envflag[@]+"${envflag[@]}"}" >/dev/null ) && echo "  set $dest"; fi
    done
    ;;
  gha)
    [[ -n "$GHA_REPO" ]] || { echo "scope missing '# github:' directive" >&2; exit 1; }
    echo "gha: $GHA_REPO"
    confirm "Set GitHub secrets/variables on $GHA_REPO?" || { echo aborted; exit 1; }
    for e in "${KEYS[@]}"; do IFS=$'\t' read -r dest src st <<<"$e"
      v="$(resolve "$src" "$st")"; [[ -z "$v" ]] && { echo "  skip $dest (blank)"; continue; }
      if [[ "$(source_of "$src" "$st")" == variable ]]; then
        if [[ "$DRY" == 1 ]]; then echo "  would: gh variable set $dest --repo $GHA_REPO"
        else gh variable set "$dest" --repo "$GHA_REPO" --body "$v" >/dev/null && echo "  variable $dest"; fi
      else
        if [[ "$DRY" == 1 ]]; then echo "  would: gh secret set $dest --repo $GHA_REPO"
        else printf '%s' "$v" | gh secret set "$dest" --repo "$GHA_REPO" && echo "  secret $dest"; fi
      fi
    done
    ;;
  local)
    [[ -n "$FILE_REL" ]] || { echo "scope missing '# file:' directive" >&2; exit 1; }
    target_file="$DIR/$FILE_REL"
    echo "local: render $target_file (merge ${#KEYS[@]} keys)"
    tmp="$(mktemp)"; trap 'rm -f "$tmp" "$tmp.n"' EXIT
    [[ -f "$target_file" ]] && cp "$target_file" "$tmp" || : >"$tmp"
    for e in "${KEYS[@]}"; do IFS=$'\t' read -r dest src st <<<"$e"
      v="$(resolve "$src" "$st")"; [[ -z "$v" ]] && { echo "  skip $dest (blank)"; continue; }
      if grep -q "^$dest=" "$tmp"; then
        awk -v k="$dest" -v val="$v" 'BEGIN{FS=OFS="="} $1==k{print k"="val; next} {print}' "$tmp" >"$tmp.n" && mv "$tmp.n" "$tmp"
      else printf '%s=%s\n' "$dest" "$v" >>"$tmp"; fi
      echo "  set $dest"
    done
    if [[ "$DRY" == 1 ]]; then echo "  (dry-run) diff vs current:"; diff "${target_file:-/dev/null}" "$tmp" || true
    else cp "$tmp" "$target_file"; echo "  wrote $target_file"; fi
    ;;
  appwrite)
    echo "appwrite: automatic push not wired (function IDs needed). Set these as function variables:" >&2
    for e in "${KEYS[@]}"; do IFS=$'\t' read -r dest src st <<<"$e"
      v="$(resolve "$src" "$st")"; [[ -z "$v" ]] && { echo "# $dest BLANK" >&2; continue; }
      printf '%s=%s\n' "$dest" "$(mask "$v")"
    done
    ;;
  codemagic)
    # Push each key into a Codemagic app's environment variable group via the REST API.
    # secret -> secure=true, variable -> secure=false. Upsert: delete any same-key var in the
    # group, then create. Auth token from $CODEMAGIC_API_TOKEN or vault/common CODEMAGIC_API_TOKEN.
    [[ -n "$CM_GROUP" ]] || { echo "scope missing '# group:' directive" >&2; exit 1; }
    CM_TOKEN="${CODEMAGIC_API_TOKEN:-}"
    [[ -z "$CM_TOKEN" ]] && CM_TOKEN="$(de_get "$COMMON" CODEMAGIC_API_TOKEN)"
    [[ -n "$CM_TOKEN" ]] || { echo "codemagic: no API token (set \$CODEMAGIC_API_TOKEN or add CODEMAGIC_API_TOKEN to vault/common)" >&2; exit 1; }
    api="https://api.codemagic.io"
    app_id="$CM_APP_ID"
    if [[ -z "$app_id" ]]; then
      [[ -n "$CM_APP_NAME" ]] || { echo "scope missing '# app-id:' or '# app-name:' directive" >&2; exit 1; }
      app_id="$(curl -fsS -H "x-auth-token: $CM_TOKEN" "$api/apps" \
        | jq -r --arg n "$CM_APP_NAME" '.applications[]? | select(.appName==$n) | (._id // .id)' | head -n1)"
      [[ -n "$app_id" ]] || { echo "codemagic: no app named '$CM_APP_NAME'" >&2; exit 1; }
    fi
    echo "codemagic: app=$app_id group=$CM_GROUP"
    confirm "Push ${#KEYS[@]} var(s) to Codemagic group '$CM_GROUP'?" || { echo aborted; exit 1; }
    # existing vars in this group: "key<TAB>id" per line (for idempotent upsert)
    existing="$(curl -fsS -H "x-auth-token: $CM_TOKEN" "$api/apps/$app_id/variables" \
      | jq -r --arg g "$CM_GROUP" '.[] | select(.group==$g) | [.key, .id] | @tsv')"
    for e in "${KEYS[@]}"; do IFS=$'\t' read -r dest src st <<<"$e"
      v="$(resolve "$src" "$st")"; [[ -z "$v" ]] && { echo "  skip $dest (blank)"; continue; }
      if [[ "$(source_of "$src" "$st")" == secret ]]; then secure=true; else secure=false; fi
      old_id="$(awk -v k="$dest" -F'\t' '$1==k{print $2; exit}' <<<"$existing")"
      if [[ "$DRY" == 1 ]]; then
        echo "  would: set $dest (secure=$secure)${old_id:+ — replacing $old_id}"; continue
      fi
      [[ -n "$old_id" ]] && curl -fsS -X DELETE -H "x-auth-token: $CM_TOKEN" "$api/apps/$app_id/variables/$old_id" >/dev/null
      body="$(jq -nc --arg k "$dest" --arg v "$v" --arg g "$CM_GROUP" --argjson s "$secure" '{key:$k,value:$v,group:$g,secure:$s}')"
      printf '%s' "$body" | curl -fsS -X POST -H "x-auth-token: $CM_TOKEN" -H "Content-Type: application/json" \
        --data-binary @- "$api/apps/$app_id/variables" >/dev/null && echo "  set $dest (secure=$secure)"
    done
    ;;
  *) echo "unknown target: $TARGET" >&2; exit 1 ;;
  esac
  ;;
esac
