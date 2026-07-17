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

run_tool() {
  local dir="$1" tool="$2"; shift 2
  (
    cd "$dir"
    PATH="$FAKE_BIN:$PATH" \
      SECRETS_VAULT_DIR="$TMP/vault" \
      SECRETS_VAULT_CLOUD_DIR=none \
      SECRETS_VAULT_SERVICE= \
      "$tool" "$@"
  )
}
run_in() { local dir="$1"; shift; run_tool "$dir" "$SCRIPT" "$@"; }

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
  PATH="$FAKE_BIN:$PATH" \
    SECRETS_VAULT_DIR="$TMP/vault" \
    SECRETS_VAULT_CLOUD_DIR=none \
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

# ---- linked worktrees (`git worktree add`, .git is a FILE) — the wrapper-repo layout ----
WRAP="$TMP/wrap"
mkdir -p "$WRAP"
git -C "$WRAP" init -q
git -C "$WRAP" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$WRAP" worktree add -q "$WRAP/feature-x" -b feature-x
[[ -f "$WRAP/feature-x/.git" ]] || fail "expected linked worktree .git to be a file"
mkdir -p "$WRAP/feature-x/environments" "$WRAP/feature-x/sub"
printf 'service: host-svc\nrepo: host\n' >"$WRAP/feature-x/environments/manifest.yaml"
printf 'FOO=host-val\n' >"$WRAP/feature-x/environments/variables"
printf '# target: appwrite\nFOO\n' >"$WRAP/feature-x/environments/local"

output="$(run_in "$WRAP/feature-x/sub" check local --stage sandbox)"
assert_contains "$output" "service=host-svc  target=appwrite"

WRAP_REAL="$(cd "$WRAP" && pwd -P)"
if output="$(run_in "$WRAP" check local --stage sandbox 2>&1)"; then
  fail "empty wrapper root unexpectedly resolved a project"
fi
assert_contains "$output" "current worktree has no environments/manifest.yaml: $WRAP_REAL"

# a linked worktree nested INSIDE another worktree (external/<repo>) resolves to itself
INNER_WRAP="$TMP/inner-wrap"
mkdir -p "$INNER_WRAP"
git -C "$INNER_WRAP" init -q
git -C "$INNER_WRAP" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$INNER_WRAP" worktree add -q "$WRAP/feature-x/external/inner" -b linked
[[ -f "$WRAP/feature-x/external/inner/.git" ]] || fail "expected nested worktree .git to be a file"
mkdir -p "$WRAP/feature-x/external/inner/environments"
printf 'service: inner-svc\nrepo: inner\n' >"$WRAP/feature-x/external/inner/environments/manifest.yaml"
printf 'FOO=inner-val\n' >"$WRAP/feature-x/external/inner/environments/variables"
printf '# target: appwrite\nFOO\n' >"$WRAP/feature-x/external/inner/environments/local"

output="$(run_in "$WRAP/feature-x/external/inner" check local --stage sandbox)"
assert_contains "$output" "service=inner-svc  target=appwrite"
output="$(run_in "$WRAP/feature-x" check local --stage sandbox)"
assert_contains "$output" "service=host-svc  target=appwrite"

# ---- deleted cwd errors instead of looping forever ----
# Watchdog kills the whole process GROUP after 10s: a plain alarm+exec is not enough, since
# the hang under test lives in a command-substitution subshell, which survives its
# alarm-killed parent and keeps the capture pipe open (the suite would hang, not fail).
run_with_watchdog() {
  perl -e '
    setpgrp(0, 0);
    my $pid = fork; defined $pid or exit 127;
    if ($pid == 0) { exec @ARGV; exit 127 }
    $SIG{ALRM} = sub { kill 9, -$$ };
    alarm 10;
    waitpid $pid, 0;
    exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
  ' -- "$@"
}

GONE="$TMP/gone"
mkdir -p "$GONE"
if output="$(
  cd "$GONE" && rmdir "$GONE" || exit 1
  export PATH="$FAKE_BIN:$PATH" SECRETS_VAULT_DIR="$TMP/vault" SECRETS_VAULT_CLOUD_DIR=none
  run_with_watchdog "$SCRIPT" check local --stage sandbox 2>&1
)"; then
  fail "command from a deleted cwd unexpectedly succeeded"
fi
assert_contains "$output" "not inside a Git worktree"

# ---- vault-* commands without project context print guidance, not a silent death ----
if output="$(run_tool "$CHILD" "$HERE/scripts/vault-show.sh" production 2>&1)"; then
  fail "vault-show without project context unexpectedly succeeded"
fi
assert_contains "$output" "no service: pass --service"

echo "current-worktree resolver: ok"
