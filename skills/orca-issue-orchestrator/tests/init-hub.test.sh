#!/usr/bin/env bash
# Executable-boundary tests for scripts/init-hub.sh.
#
# Runs init-hub against a temporary Hub folder with a fake HOME and a fake
# `orca` first on PATH (it answers `orca repo list --json` and logs its
# arguments), and asserts on what leaves the script: stdout, the exit code,
# and the files it writes. Dependencies: bash, jq, coreutils.
#
# Usage: tests/init-hub.test.sh

# jq programs and sh -c scripts below are single-quoted on purpose.
# shellcheck disable=SC2016

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT="$SCRIPT_DIR/../scripts/init-hub.sh"
GUARD_SRC="$SCRIPT_DIR/../scripts/guard.sh"

REASON='Editing code is forbidden in the orchestrator. Create a Task with orca orchestration and delegate it (see /orca-issue-orchestrator).'
DENIES='["Bash(rm -rf *)","Bash(git push *)","Bash(gh issue close *)","Bash(gh issue delete *)","Bash(gh pr merge *)","Bash(gh repo delete *)"]'
FILES='CLAUDE.md AGENTS.md .claude/settings.json .claude/agents/orchestrator.md .codex/config.toml .codex/rules/orchestrator.rules .orca-hub/hub.json .orca-hub/guard.sh'
DIRS='docs research tmp'

pass=0
fail=0

# --- fixtures ---------------------------------------------------------------

WORK="$(mktemp -d "${TMPDIR:-/tmp}/inithubXXXXXX")"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd -P)"

# A fake HOME with the directories init-hub must never touch.
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME/.claude" "$FAKE_HOME/.codex" "$FAKE_HOME/.orca"
echo '{"hooks":{}}' > "$FAKE_HOME/.claude/settings.json"
echo 'model = "x"' > "$FAKE_HOME/.codex/config.toml"
echo '{}' > "$FAKE_HOME/.orca/state.json"

# The fake orca: `repo list --json` reports every folder listed in
# $WORK/orca-folders (one path per line) as an Orca folder workspace.
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/orca" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ORCA_LOG"
if [ "$1 $2" = "repo list" ]; then
  jq -R -s -c '{ok: true, result: {repos: [split("\n")[] | select(. != "") | {id: ("id-" + .), path: ., kind: "folder", displayName: "hub"}]}}' "$ORCA_FOLDERS"
  exit 0
fi
echo "fake orca: unexpected call: $*" >&2
exit 1
EOF
chmod +x "$BIN/orca"
export ORCA_LOG="$WORK/orca.log"
export ORCA_FOLDERS="$WORK/orca-folders"
: > "$ORCA_LOG"
: > "$ORCA_FOLDERS"

# new_hub <name>: create an empty Hub folder registered with the fake orca.
new_hub() {
  local dir="$WORK/$1"
  mkdir -p "$dir"
  printf '%s\n' "$dir" >> "$ORCA_FOLDERS"
  printf '%s\n' "$dir"
}

# snapshot <dir>: print every path and the checksum of every file under <dir>.
snapshot() {
  (cd "$1" && find . -print | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort)
}

# run_init <args...>  -> sets OUT and CODE
run_init() {
  OUT="$(HOME="$FAKE_HOME" PATH="$BIN:$PATH" "$BASH" "$INIT" "$@" 2>&1)"
  CODE=$?
}

ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
fail_case() { fail=$((fail + 1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

# check <name> <command...>: pass when the command succeeds.
check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else fail_case "$name" "command failed: $*"; fi
}

contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

home_before="$(snapshot "$FAKE_HOME")"

# --- dry-run ------------------------------------------------------------------

HUB="$(new_hub hub)"
before="$(snapshot "$HUB")"
run_init "$HUB"
check "dry-run exits 0" [ "$CODE" -eq 0 ]
check "dry-run writes nothing" [ "$(snapshot "$HUB")" = "$before" ]
for f in $FILES $DIRS; do
  check "dry-run lists $f" contains "$OUT" "$f"
done
check "dry-run says how to apply" contains "$OUT" "--apply"

# --- apply --------------------------------------------------------------------

run_init "$HUB" --apply
check "apply exits 0" [ "$CODE" -eq 0 ]
for f in $FILES; do
  check "apply writes $f" [ -f "$HUB/$f" ]
done
for d in $DIRS; do
  check "apply creates empty $d/" [ -d "$HUB/$d" ]
  check "$d/ is empty" [ -z "$(ls -A "$HUB/$d")" ]
done

check "AGENTS.md has the same content as CLAUDE.md" cmp -s "$HUB/CLAUDE.md" "$HUB/AGENTS.md"
check "CLAUDE.md points at the skill" grep -q 'orca-issue-orchestrator' "$HUB/CLAUDE.md"

S="$HUB/.claude/settings.json"
check "settings.json is valid JSON" jq -e . "$S" >/dev/null
check "settings.json registers the Guard as a PreToolUse hook for Bash|Edit|Write|NotebookEdit" \
  jq -e --arg g "$HUB/.orca-hub/guard.sh" \
  'any(.hooks.PreToolUse[]; .matcher == "Bash|Edit|Write|NotebookEdit" and any(.hooks[]; .type == "command" and (.command | contains($g))))' "$S"
check "settings.json denies exactly the six destructive commands" \
  jq -e --argjson d "$DENIES" '.permissions.deny == $d' "$S"
check "settings.json never sets the agent key" jq -e 'has("agent") | not' "$S"

A="$HUB/.claude/agents/orchestrator.md"
check "orchestrator agent has a name" grep -q '^name: orchestrator$' "$A"
tools_line="$(grep '^tools:' "$A")"
check "orchestrator agent lists tools" [ -n "$tools_line" ]
for t in Edit Write NotebookEdit; do
  check "orchestrator agent has no $t tool" sh -c 'printf "%s\n" "$1" | tr -s ", " "\n\n" | grep -qx "$2" && exit 1 || exit 0' _ "$tools_line" "$t"
done

C="$HUB/.codex/config.toml"
check "codex config: read-only sandbox" grep -qx 'sandbox_mode = "read-only"' "$C"
check "codex config: approval never" grep -qx 'approval_policy = "never"' "$C"
check "no .codex/hooks.json" [ ! -e "$HUB/.codex/hooks.json" ]

R="$HUB/.codex/rules/orchestrator.rules"
allowed="$(sed -n "s/^ALLOWED_COMMANDS='\(.*\)'$/\1/p" "$GUARD_SRC")"
allowed_git="$(sed -n "s/^ALLOWED_GIT='\(.*\)'$/\1/p" "$GUARD_SRC")"
check "guard.sh command allowlist is readable" [ -n "$allowed" ]
check "guard.sh git allowlist is readable" [ -n "$allowed_git" ]
for w in $allowed; do
  [ "$w" = git ] && continue
  check "rules allow $w" grep -qF "prefix_rule(pattern = [\"$w\"], decision = \"allow\")" "$R"
done
for w in $allowed_git; do
  check "rules allow git $w" grep -qF "prefix_rule(pattern = [\"git\", \"$w\"], decision = \"allow\")" "$R"
done
check "rules do not allow bare git" sh -c '! grep -qF "prefix_rule(pattern = [\"git\"]," "$1"' _ "$R"
for p in "\"rm\", \"-rf\"" "\"git\", \"push\"" "\"gh\", \"issue\", \"close\"" "\"gh\", \"issue\", \"delete\"" "\"gh\", \"pr\", \"merge\"" "\"gh\", \"repo\", \"delete\""; do
  check "rules forbid [$p] (the permissions.deny list)" grep -qF "prefix_rule(pattern = [$p], decision = \"forbidden\")" "$R"
done

H="$HUB/.orca-hub/hub.json"
check "hub.json hub_path is the Hub folder" jq -e --arg h "$HUB" '.hub_path == $h' "$H"
check "hub.json has hub_id, concurrency, repos, bash_allow" \
  jq -e '(.hub_id | type == "string" and length > 0) and .concurrency == 1 and (.repos | type == "array") and (.bash_allow | type == "array")' "$H"

G="$HUB/.orca-hub/guard.sh"
check "guard.sh is a copy, not a symlink" [ ! -L "$G" ]
check "guard.sh is executable" [ -x "$G" ]
check "guard.sh carries a version marker" grep -q '^# installed-by: orca-issue-orchestrator init-hub' "$G"
out="$(jq -nc --arg p "$HUB/src/x.py" '{tool_name: "Write", tool_input: {file_path: $p, content: "x"}}' | CLAUDE_PROJECT_DIR="$HUB" bash "$G")"
check "the installed Guard denies a write outside the allowed directories" \
  sh -c 'printf "%s" "$1" | jq -e --arg r "$2" ".hookSpecificOutput.permissionDecisionReason == \$r" >/dev/null' _ "$out" "$REASON"
out="$(jq -nc --arg p "$HUB/docs/n.md" '{tool_name: "Write", tool_input: {file_path: $p, content: "x"}}' | CLAUDE_PROJECT_DIR="$HUB" bash "$G")"
check "the installed Guard allows a write under docs/" [ -z "$out" ]

check "apply prints the Codex launch command" \
  contains "$OUT" "orca terminal create --worktree path:$HUB --command \"codex --sandbox read-only -a never -c projects.$HUB.trust_level=trusted\""
case "$HUB" in
  *.*) ;;
  *) check "no CODEX_HOME alternative when the path has no dot" sh -c '! printf "%s" "$1" | grep -q CODEX_HOME' _ "$OUT" ;;
esac

# --- idempotence ----------------------------------------------------------------

before="$(snapshot "$HUB")"
run_init "$HUB" --apply
check "second apply exits 0" [ "$CODE" -eq 0 ]
check "second apply reports no changes" contains "$OUT" "No changes"
check "second apply changes no file" [ "$(snapshot "$HUB")" = "$before" ]
check "second apply makes no backup" [ -z "$(find "$HUB" -name '*.bak.*')" ]

# --- merge into an existing settings.json ------------------------------------------

HUB2="$(new_hub merge)"
mkdir -p "$HUB2/.claude"
cat > "$HUB2/.claude/settings.json" <<'EOF'
{
  "model": "opus",
  "hooks": {
    "PreToolUse": [
      { "matcher": "Read", "hooks": [ { "type": "command", "command": "echo unrelated" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "echo stop" } ] }
    ]
  },
  "permissions": { "deny": ["Bash(curl *)", "Bash(git push *)"], "allow": ["Bash(ls *)"] }
}
EOF
echo '# my notes' > "$HUB2/CLAUDE.md"
run_init "$HUB2"
check "dry-run on an existing settings.json plans a backup" contains "$OUT" "backup"
run_init "$HUB2" --apply
S2="$HUB2/.claude/settings.json"
check "merge: apply exits 0" [ "$CODE" -eq 0 ]
check "merge keeps the unrelated PreToolUse hook" \
  jq -e 'any(.hooks.PreToolUse[]; .matcher == "Read" and .hooks[0].command == "echo unrelated")' "$S2"
check "merge adds the Guard hook" \
  jq -e --arg g "$HUB2/.orca-hub/guard.sh" 'any(.hooks.PreToolUse[]; any(.hooks[]; .command | contains($g)))' "$S2"
check "merge keeps other hook events" jq -e '.hooks.Stop[0].hooks[0].command == "echo stop"' "$S2"
check "merge keeps other keys" jq -e '.model == "opus" and .permissions.allow == ["Bash(ls *)"]' "$S2"
check "merge keeps existing denies and adds the six without duplicates" \
  jq -e --argjson d "$DENIES" '(.permissions.deny | index("Bash(curl *)")) != null and ($d - .permissions.deny) == [] and (.permissions.deny | length) == 7' "$S2"
check "merge never sets the agent key" jq -e 'has("agent") | not' "$S2"
backup="$(find "$HUB2/.claude" -name 'settings.json.bak.*' | head -1)"
check "a timestamped backup of settings.json exists" [ -n "$backup" ]
check "the backup holds the original settings" jq -e '.model == "opus" and (.hooks.PreToolUse | length) == 1' "$backup"
check "a backup of the overwritten CLAUDE.md exists" sh -c 'ls "$1"/CLAUDE.md.bak.* >/dev/null 2>&1' _ "$HUB2"
run_init "$HUB2" --apply
check "merge: second apply reports no changes" contains "$OUT" "No changes"
check "merge: the Guard hook appears once" \
  jq -e --arg g "$HUB2/.orca-hub/guard.sh" '[.hooks.PreToolUse[] | .hooks[] | select(.command | contains($g))] | length == 1' "$S2"

# --- hub.json from arguments, kept on re-run -------------------------------------

HUB3="$(new_hub args)"
run_init "$HUB3" --apply --hub-id example --repo '<owner>/<repo>' --concurrency 2 --bash-allow make
H3="$HUB3/.orca-hub/hub.json"
check "hub.json from arguments" \
  jq -e '.hub_id == "example" and .concurrency == 2 and .repos == [{name: "<owner>/<repo>"}] and .bash_allow == ["make"]' "$H3"
check "bash_allow is mirrored into the Codex rules" \
  grep -qF 'prefix_rule(pattern = ["make"], decision = "allow")' "$HUB3/.codex/rules/orchestrator.rules"
jq '.repos += [{name: "<owner>/<other-repo>", base_branch: "develop"}]' "$H3" > "$WORK/h.json" && cat "$WORK/h.json" > "$H3"
run_init "$HUB3" --apply
check "a re-run keeps hand edits to hub.json" jq -e '(.repos | length) == 2 and .hub_id == "example"' "$H3"
check "a re-run after hand edits reports no changes" contains "$OUT" "No changes"

# --- a Hub path with a dot -------------------------------------------------------

HUB4="$(new_hub dotted.hub)"
run_init "$HUB4"
check "a dotted path prints the CODEX_HOME alternative" contains "$OUT" "CODEX_HOME=$HUB4/.codex-home"

# --- not an Orca folder workspace ------------------------------------------------

mkdir -p "$WORK/unregistered"
run_init "$WORK/unregistered" --apply
check "an unregistered folder exits non-zero" [ "$CODE" -ne 0 ]
check "an unregistered folder prints the setup command" \
  contains "$OUT" "orca project setup-existing-folder"
check "the setup command uses --kind folder" contains "$OUT" "--kind folder"
check "an unregistered folder gets no files" [ -z "$(ls -A "$WORK/unregistered")" ]

run_init "$WORK/missing"
check "a missing folder exits non-zero" [ "$CODE" -ne 0 ]
check "a missing folder prints the setup command" contains "$OUT" "orca project setup-existing-folder"
check "a missing folder is not created" [ ! -e "$WORK/missing" ]

run_init
check "no arguments exits non-zero with usage" sh -c '[ "$1" -ne 0 ] && printf "%s" "$2" | grep -q Usage' _ "$CODE" "$OUT"

# --- nothing outside the Hub folder ------------------------------------------------

check "nothing under the fake HOME changed" [ "$(snapshot "$FAKE_HOME")" = "$home_before" ]
check "orca was only asked to list repos" sh -c '! grep -v "^repo list --json$" "$1"' _ "$ORCA_LOG"

# --- summary ------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
