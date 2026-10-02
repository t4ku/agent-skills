#!/usr/bin/env bash
# Shared setup for the executable-boundary tests of the Issue scripts.
#
# Source it from a tests/*.test.sh file. It builds a temporary Hub folder,
# puts the fake `gh` and `orca` (tests/bin/) first on PATH, and defines the
# run / check / call-log helpers. The fakes answer from tests/fixtures/ and
# append every argv to $FAKE_LOG, one JSON array per line. The paginated
# `gh api` answers come in pages of $FAKE_PAGE_SIZE (default 100) items;
# reset_fakes unsets it.
# Dependencies: bash, jq, coreutils.

# The bash -c snippets expand their variables in the child shell.
# shellcheck disable=SC2016,SC2034  # variables are used by the sourcing test

HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$HELPERS_DIR/../scripts"
FIXTURES="$HELPERS_DIR/fixtures"

pass=0
fail=0

# --- fixtures ---------------------------------------------------------------

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd -P)"

HUB="$WORK/hub"
mkdir -p "$HUB/.orca-hub"
jq -n --arg hub "$HUB" '{
  hub_id: "example-hub",
  hub_path: $hub,
  concurrency: 1,
  repos: [
    {name: "example/app"},
    {name: "example/api", base_branch: "develop",
     constraints: ["Run the full test suite before opening the PR."]}
  ]
}' > "$HUB/.orca-hub/hub.json"

export PATH="$HELPERS_DIR/bin:$PATH"
export FAKE_FIXTURES="$FIXTURES"
export FAKE_LOG="$WORK/calls.log"

# Per-test overrides of single fixtures; an empty <fixture>.fail makes the
# fake exit 1 for that fixture.
OVR="$WORK/overrides"

# --- helpers ----------------------------------------------------------------

reset_fakes() {
  : > "$FAKE_LOG"
  rm -f "$FAKE_LOG.comment"
  rm -rf "$OVR"
  unset FAKE_PAGE_SIZE
  mkdir -p "$OVR"
  export FAKE_OVERRIDES="$OVR"
}

# run <script> <args...>  -> sets OUT (stdout+stderr) and CODE
run() {
  OUT="$(cd "$HUB" && bash "$@" 2>&1)"
  CODE=$?
}

# run_stdin <file> <script> <args...>
run_stdin() {
  local input="$1"
  shift
  OUT="$(cd "$HUB" && bash "$@" < "$input" 2>&1)"
  CODE=$?
}

ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
fail_case() { fail=$((fail + 1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

# check <name> <condition command...>
check() {
  local name="$1"
  shift
  if "$@"; then ok "$name"; else fail_case "$name" "output was:
$OUT"; fi
}

out_has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
out_has_line() { printf '%s\n' "$OUT" | grep -qxF -- "$1"; }
out_lacks() { ! out_has "$1"; }
code_is() { [ "$CODE" -eq "$1" ]; }

# line_no <exact line>: first line number of an exact line in OUT.
line_no() { printf '%s\n' "$OUT" | grep -nxF -- "$1" | head -1 | cut -d: -f1; }

# The log as one line per call, argv joined by spaces (newlines escaped).
calls() { jq -r 'map(gsub("\n"; "\\n")) | join(" ")' "$FAKE_LOG"; }

# Calls that change GitHub or Orca state.
MUTATION_RE='^(gh issue (edit|comment|close|create|delete|reopen)|gh pr (create|merge|close|edit|comment)|gh label |orca orchestration (task-create|task-update|worker-start|worker-release|run-create|run-use|dispatch|send)|orca worktree (set|create|rm)|orca terminal )'

no_mutation() { ! calls | grep -Eq "$MUTATION_RE"; }
# The mutating calls only, in order.
mutations() { calls | grep -E "$MUTATION_RE"; }
# mutations_of: the same, callable from the `bash -c` snippets of a check.
mutations_of() { mutations; }
export MUTATION_RE
export -f calls mutations mutations_of
# call_line <prefix>: line number of the first call starting with <prefix>.
call_line() { calls | awk -v p="$1" 'index($0, p) == 1 { print NR; exit }'; }
called() { [ -n "$(call_line "$1")" ]; }
not_called() { ! called "$1"; }

# no_abs_path <file>: the file holds no local path, by the classifier the
# scripts use before posting (local_path_fragment in scripts/lib.sh), with the
# test Hub as the Hub folder.
no_abs_path() {
  ! (
    HUB_DIR="$HUB"
    # shellcheck source=../scripts/lib.sh disable=SC1091
    . "$SCRIPTS/lib.sh"
    local_path_fragment "$(cat "$1")" > /dev/null
  )
}

# summary: print the tally; return non-zero when a check failed.
summary() {
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
}
