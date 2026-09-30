#!/usr/bin/env bash
# Hook-contract tests for scripts/guard.sh.
#
# Feeds PreToolUse JSON (the shape Claude Code sends on stdin) to the Guard
# with CLAUDE_PROJECT_DIR set, and asserts on what leaves it: stdout and the
# exit code. Dependencies: bash, jq, coreutils.
#
# Usage: tests/guard.test.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../scripts/guard.sh"

REASON='Editing code is forbidden in the orchestrator. Create a Task with orca orchestration and delegate it (see /orca-issue-orchestrator).'

pass=0
fail=0

# --- fixtures ---------------------------------------------------------------

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd -P)"

HUB="$WORK/hub"
OTHER="$WORK/elsewhere"
mkdir -p "$HUB/docs" "$HUB/research" "$HUB/tmp" "$HUB/.orca-hub" "$HUB/src" "$OTHER"
ln -s "$HUB/src" "$HUB/docs/link-to-src"

jq -n --arg hub "$HUB" '{
  hub_id: "example",
  hub_path: $hub,
  concurrency: 1,
  repos: [{name: "<owner>/<repo>"}],
  bash_allow: ["make"]
}' > "$HUB/.orca-hub/hub.json"

# Another folder with a hub.json whose hub_path points elsewhere.
mkdir -p "$OTHER/.orca-hub"
jq -n --arg hub "$HUB" '{hub_id: "example", hub_path: $hub}' > "$OTHER/.orca-hub/hub.json"

# --- helpers ----------------------------------------------------------------

# hook_json <tool_name> <tool_input JSON> [agent_id]
hook_json() {
  local agent_id="${3:-}"
  jq -nc --arg tool "$1" --argjson input "$2" --arg cwd "$HUB" --arg agent "$agent_id" '{
    session_id: "s-1",
    cwd: $cwd,
    hook_event_name: "PreToolUse",
    tool_name: $tool,
    tool_input: $input,
    tool_use_id: "toolu_1",
    permission_mode: "default"
  } + (if $agent == "" then {} else {agent_id: $agent, agent_type: "general-purpose"} end)'
}

bash_json() { hook_json Bash "$(jq -nc --arg c "$1" '{command: $c, description: "test"}')"; }
write_json() { hook_json Write "$(jq -nc --arg p "$1" '{file_path: $p, content: "x"}')" "${2:-}"; }
edit_json() { hook_json Edit "$(jq -nc --arg p "$1" '{file_path: $p, old_string: "a", new_string: "b"}')"; }
notebook_json() { hook_json NotebookEdit "$(jq -nc --arg p "$1" '{notebook_path: $p, new_source: "x"}')"; }

# run_guard <project dir> <stdin JSON>  -> sets OUT and CODE
run_guard() {
  OUT="$(printf '%s' "$2" | CLAUDE_PROJECT_DIR="$1" bash "$GUARD")"
  CODE=$?
}

ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
fail_case() { fail=$((fail + 1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

# expect_allow <name> <stdin JSON> [project dir]
expect_allow() {
  run_guard "${3-$HUB}" "$2"
  if [ "$CODE" -eq 0 ] && [ -z "$OUT" ]; then
    ok "$1"
  else
    fail_case "$1" "want no output and exit 0, got exit $CODE, stdout: $OUT"
  fi
}

# expect_deny <name> <stdin JSON> [blocked token]
expect_deny() {
  local want="$REASON"
  if [ -n "${3:-}" ]; then
    want="$REASON Blocked segment: $3"
  fi
  run_guard "$HUB" "$2"
  local got
  got="$(printf '%s' "$OUT" | jq -c . 2>/dev/null)"
  local exp
  exp="$(jq -nc --arg r "$want" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}')"
  if [ "$CODE" -eq 0 ] && [ "$got" = "$exp" ]; then
    ok "$1"
  else
    fail_case "$1" "want exit 0 and $exp, got exit $CODE, stdout: $OUT"
  fi
}

# --- session matching -------------------------------------------------------

expect_allow "project dir that is not the Hub folder: Write outside is not judged" "$(write_json "$OTHER/x.txt")" "$OTHER"
expect_allow "project dir that is not the Hub folder: denied Bash is not judged" "$(bash_json 'rm -rf x')" "$OTHER"
expect_allow "project dir without hub.json is not judged" "$(write_json "$WORK/x.txt")" "$WORK"
expect_allow "empty CLAUDE_PROJECT_DIR is not judged" "$(write_json "$WORK/x.txt")" ""
expect_allow "Hub folder path with a trailing slash is not an exact match" "$(write_json "$HUB/src/x.txt")" "$HUB/"

# --- Edit / Write / NotebookEdit ---------------------------------------------

for d in docs research tmp .orca-hub; do
  expect_allow "Write under $d/" "$(write_json "$HUB/$d/note.md")"
  expect_allow "Edit under $d/ (nested, new dir)" "$(edit_json "$HUB/$d/a/b/note.md")"
  expect_allow "NotebookEdit under $d/" "$(notebook_json "$HUB/$d/nb.ipynb")"
done

expect_deny "Write at the Hub folder root" "$(write_json "$HUB/CLAUDE.md")"
expect_deny "Edit in another Hub folder subdirectory" "$(edit_json "$HUB/src/main.sh")"
expect_deny "Write to the Hub folder .claude/settings.json" "$(write_json "$HUB/.claude/settings.json")"
expect_deny "Write outside the Hub folder" "$(write_json "$OTHER/x.txt")"
expect_deny "NotebookEdit outside the Hub folder" "$(notebook_json "$OTHER/nb.ipynb")"
expect_deny "Write to a sibling that shares the prefix (docs-evil/)" "$(write_json "$HUB/docs-evil/x.md")"
expect_deny "Write escaping docs/ with .." "$(write_json "$HUB/docs/../src/x.sh")"
expect_deny "Write escaping via a new dir and .." "$(write_json "$HUB/docs/new/../../src/x.sh")"
expect_deny "Write through a symlink out of docs/ (realpath)" "$(write_json "$HUB/docs/link-to-src/x.sh")"
expect_deny "Write to the docs directory itself" "$(write_json "$HUB/docs")"
expect_deny "Write with an empty file_path" "$(write_json "")"
expect_allow "relative file_path resolves against the Hub folder" "$(write_json "tmp/scratch.txt")"
expect_deny "relative file_path outside the allowed dirs" "$(write_json "src/x.sh")"

# --- subagents (agent_id present) --------------------------------------------

expect_deny "subagent Write outside the allowed dirs" "$(write_json "$HUB/src/x.sh" a23b4893193300384)"
expect_deny "subagent Bash with a denied command" \
  "$(hook_json Bash '{"command":"python x.py","description":"d"}' a23b4893193300384)" python
expect_allow "subagent Bash with an allowed command" \
  "$(hook_json Bash '{"command":"gh issue list","description":"d"}' a23b4893193300384)"
expect_allow "subagent Write under research/" "$(write_json "$HUB/research/r.md" a23b4893193300384)"
expect_allow "Agent tool call is allowed" \
  "$(hook_json Agent '{"description":"d","prompt":"p","subagent_type":"general-purpose"}')"
expect_allow "Read tool call is allowed" "$(hook_json Read "$(jq -nc --arg p "$HUB/src/x" '{file_path: $p}')")"

# --- Bash ---------------------------------------------------------------------

expect_allow "Bash: gh" "$(bash_json 'gh issue view 123')"
expect_allow "Bash: orca" "$(bash_json 'orca orchestration check --json')"
expect_allow "Bash: read-only git" "$(bash_json 'git log --oneline -5')"
expect_allow "Bash: leading whitespace" "$(bash_json '   ls -la')"
expect_allow "Bash: [ test" "$(bash_json '[ -d docs ] && echo yes')"
expect_allow "Bash: compound all allowed" \
  "$(bash_json 'cd docs && ls; git status || true | wc -l')"
expect_allow "Bash: pipe inside quotes is not a separator" \
  "$(bash_json "gh issue list --json number | jq '.[] | .number'")"
expect_deny "Bash: escaped quote does not hide a separator" \
  "$(bash_json 'echo "a\"b"; python x.py')" python
expect_deny "Bash: \$'...' quote does not hide a separator" \
  "$(bash_json "echo \$'\\'' ; sed -i s/a/b/ src.py")" sed
expect_allow "Bash: \$'...' quote keeps its separators inside" "$(bash_json "echo \$'a;b' | wc -c")"
expect_allow "Bash: skill script by basename" "$(bash_json '/path/to/scripts/issue-dispatch.sh 123')"
expect_allow "Bash: frontier.sh by basename" "$(bash_json './frontier.sh')"
expect_deny "Bash: skill script basename needs .sh" "$(bash_json '/usr/local/bin/issue-x')" '/usr/local/bin/issue-x'
expect_allow "Bash: bash_allow[] from hub.json" "$(bash_json 'make docs')"

expect_deny "Bash: command not on the allowlist" "$(bash_json 'rm -rf src')" rm
expect_deny "Bash: git subcommand not allowed" "$(bash_json 'git commit -m x')" "git commit"
expect_deny "Bash: git without a subcommand" "$(bash_json 'git')" "git"
expect_deny "Bash: compound with a denied segment after &&" "$(bash_json 'ls && python x.py')" python
expect_deny "Bash: compound with a denied segment after ||" "$(bash_json 'false || ls')" false
expect_deny "Bash: compound with a denied segment after ;" "$(bash_json 'ls; sed -i s/a/b/ f')" sed
expect_deny "Bash: compound with a denied segment after |" "$(bash_json 'cat f | tee out')" tee
expect_deny "Bash: denied segment after a newline" "$(bash_json "$(printf 'ls\nnpm install')")" npm
expect_deny "Bash: denied segment after a background &" "$(bash_json 'ls & sh x.sh')" sh
expect_deny "Bash: segment with >" "$(bash_json 'echo hi > src/x')" '>'
expect_deny "Bash: segment with >>" "$(bash_json 'ls && cat a >> b')" '>'
expect_deny "Bash: env assignment prefix" "$(bash_json 'FOO=1 gh issue list')" 'FOO=1'
expect_deny "Bash: skill scripts are matched by exact basename pattern" "$(bash_json './myissue-x.sh')" './myissue-x.sh'

# --- malformed input in the Hub folder ------------------------------------------------

expect_deny "malformed stdin in the Hub folder is denied" 'not json'

# --- summary ------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
