#!/usr/bin/env bash

set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/scripts/secrets.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() {
  local text="$1" pattern="$2"
  grep -qF "$pattern" <<<"$text" || fail "expected output to contain: $pattern"
}

FAKE_BIN="$TMP/bin"
PROJECT="$TMP/project"
mkdir -p "$FAKE_BIN" "$PROJECT/environments" "$PROJECT/nested/deeper" "$TMP/outside"
git -C "$PROJECT" init -q
PROJECT_REAL="$(cd "$PROJECT" && pwd -P)"

for name in age age-keygen security; do
  printf '#!/usr/bin/env bash\nexit 1\n' >"$FAKE_BIN/$name"
  chmod +x "$FAKE_BIN/$name"
done

printf 'service: current-worktree-test\nrepo: demo\n' >"$PROJECT/environments/manifest.yaml"
printf 'FOO=bar\n' >"$PROJECT/environments/variables"
printf '# target: appwrite\nFOO\n' >"$PROJECT/environments/local"

run_in() {
  local dir="$1"; shift
  (
    cd "$dir"
    PATH="$FAKE_BIN:$PATH" \
      SECRETS_VAULT_DIR="$TMP/vault" \
      SECRETS_VAULT_CLOUD_DIR=none \
      "$SCRIPT" "$@"
  )
}

output="$(run_in "$PROJECT/nested/deeper" check local --stage sandbox)"
assert_contains "$output" "variable  ok"
assert_contains "$output" "service=current-worktree-test  target=appwrite"
assert_contains "$output" "blank=0"

ln -s "$PROJECT/nested" "$TMP/project-link"
output="$(run_in "$TMP/project-link/deeper" check local --stage sandbox)"
assert_contains "$output" "service=current-worktree-test  target=appwrite"

output="$(run_in "$PROJECT" check demo/local --stage sandbox)"
assert_contains "$output" "service=current-worktree-test  target=appwrite"

if output="$(run_in "$PROJECT" check wrong/local --stage sandbox 2>&1)"; then
  fail "mismatched legacy repo/scope syntax unexpectedly succeeded"
fi
assert_contains "$output" "repo 'wrong' does not match current worktree manifest repo 'demo'"

if output="$(run_in "$PROJECT" check demo/local/extra --stage sandbox 2>&1)"; then
  fail "nested scope path unexpectedly succeeded"
fi
assert_contains "$output" "scope must be one file name"

if output="$(run_in "$PROJECT" check missing --stage sandbox 2>&1)"; then
  fail "missing scope unexpectedly succeeded"
fi
assert_contains "$output" "no scope file: $PROJECT_REAL/environments/missing"

if output="$(
  cd "$TMP/outside"
  SECRETS_VAULT_REPOS_ROOT="$TMP" \
    SECRETS_VAULT_CACHE="$TMP/cache" \
    "$SCRIPT" check local --stage sandbox 2>&1
)"; then
  fail "command outside a worktree unexpectedly succeeded"
fi
assert_contains "$output" "not inside a Git worktree"
[[ ! -e "$TMP/cache" ]] || fail "obsolete repository cache was created"

CHILD="$PROJECT/child"
mkdir -p "$CHILD/nested"
git -C "$CHILD" init -q
CHILD_REAL="$(cd "$CHILD" && pwd -P)"
if output="$(run_in "$CHILD/nested" check local --stage sandbox 2>&1)"; then
  fail "child worktree without a manifest unexpectedly used its parent"
fi
assert_contains "$output" "current worktree has no environments/manifest.yaml: $CHILD_REAL"

echo "current-worktree resolver: ok"
