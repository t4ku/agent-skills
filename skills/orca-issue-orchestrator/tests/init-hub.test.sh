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
# `worktree ps --json` answers the recorded fixture plus, for every folder
# listed in $WORK/app-folders, a copy of its folder-workspace row (a Hub folder
# created in the Orca app) with that path. A file $WORK/repo-list.fail or
# $WORK/worktree-ps.fail makes that call fail.
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/orca" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ORCA_LOG"
if [ -e "$ORCA_STATE/$1-$2.fail" ]; then
  echo "fake orca: $1 $2 set to fail" >&2
  exit 1
fi
if [ "$1 $2" = "repo list" ]; then
  jq -R -s -c '{ok: true, result: {repos: [split("\n")[] | select(. != "") | {id: ("id-" + .), path: ., kind: "folder", displayName: "hub"}]}}' "$ORCA_FOLDERS"
  exit 0
fi
if [ "$1 $2" = "worktree ps" ]; then
  jq -c --arg folders "$(cat "$ORCA_APP_FOLDERS")" '
    (.result.worktrees | map(select(.workspaceKind == "folder-workspace")) | first) as $t
    | .result.worktrees += [$folders | split("\n")[] | select(. != "") | $t + {path: .}]
  ' "$ORCA_PS_FIXTURE"
  exit 0
fi
echo "fake orca: unexpected call: $*" >&2
exit 1
EOF
chmod +x "$BIN/orca"
export ORCA_LOG="$WORK/orca.log"
export ORCA_FOLDERS="$WORK/orca-folders"
export ORCA_APP_FOLDERS="$WORK/app-folders"
export ORCA_PS_FIXTURE="$SCRIPT_DIR/fixtures/orca-worktree-ps.json"
export ORCA_STATE="$WORK"
: > "$ORCA_LOG"
: > "$ORCA_FOLDERS"
: > "$ORCA_APP_FOLDERS"
PS_ID="$(jq -r '.result.worktrees[] | select(.workspaceKind == "folder-workspace") | .worktreeId' "$ORCA_PS_FIXTURE")"
PS_NAME="$(jq -r '.result.worktrees[] | select(.workspaceKind == "folder-workspace") | .displayName' "$ORCA_PS_FIXTURE")"

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
check "dry-run says create for a missing CLAUDE.md" contains "$OUT" "create  CLAUDE.md"

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
check "a repo list folder records no Orca worktree id" jq -e 'has("orca_worktree_id") or has("orca_display_name") | not' "$H"

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
check "a backup of the CLAUDE.md that gained the block exists" sh -c 'ls "$1"/CLAUDE.md.bak.* >/dev/null 2>&1' _ "$HUB2"
run_init "$HUB2" --apply
check "merge: second apply reports no changes" contains "$OUT" "No changes"
check "merge: the Guard hook appears once" \
  jq -e --arg g "$HUB2/.orca-hub/guard.sh" '[.hooks.PreToolUse[] | .hooks[] | select(.command | contains($g))] | length == 1' "$S2"

# --- CLAUDE.md / AGENTS.md: a delimited block merged into existing files ---------

START='<!-- orca-issue-orchestrator:start -->'
END='<!-- orca-issue-orchestrator:end -->'

# count_lines <file> <line>: how many lines of <file> are exactly <line>.
count_lines() { grep -c -x -F -e "$2" "$1"; }
# block_of <file>: the lines from the start marker to the end marker.
block_of() { sed -n "/^$START\$/,/^$END\$/p" "$1"; }
# starts_with <file> <prefix file>: <file> begins with the bytes of <prefix file>.
starts_with() { head -c "$(wc -c < "$2" | tr -d ' ')" "$1" | cmp -s - "$2"; }

check "a missing CLAUDE.md is created with one block" sh -c '[ "$(grep -c -x -F -e "$2" "$1")" -eq 1 ] && [ "$(grep -c -x -F -e "$3" "$1")" -eq 1 ]' _ "$HUB/CLAUDE.md" "$START" "$END"
check "a missing AGENTS.md is created with the same block" cmp -s "$HUB/CLAUDE.md" "$HUB/AGENTS.md"
check "the block says never edit code" sh -c 'printf "%s" "$1" | grep -q "Never edit code"' _ "$(block_of "$HUB/CLAUDE.md")"
REF_BLOCK="$(block_of "$HUB/CLAUDE.md")"

HUB7="$(new_hub notes)"
printf '# Folder guide\n\nProject A lives in a/.\nProject B lives in b/.\n' > "$HUB7/CLAUDE.md"
printf '# Agents\n\nno trailing newline' > "$HUB7/AGENTS.md"
cp "$HUB7/CLAUDE.md" "$WORK/claude.orig"
cp "$HUB7/AGENTS.md" "$WORK/agents.orig"
before="$(snapshot "$HUB7")"
run_init "$HUB7"
check "dry-run says append block for an existing CLAUDE.md" contains "$OUT" "append block CLAUDE.md"
check "dry-run says append block for an existing AGENTS.md" contains "$OUT" "append block AGENTS.md"
check "dry-run with existing instructions writes nothing" [ "$(snapshot "$HUB7")" = "$before" ]
run_init "$HUB7" --apply
check "append: apply exits 0" [ "$CODE" -eq 0 ]
for f in CLAUDE.md AGENTS.md; do
  orig="$WORK/claude.orig"
  [ "$f" = AGENTS.md ] && orig="$WORK/agents.orig"
  check "append: $f keeps every original byte" starts_with "$HUB7/$f" "$orig"
  check "append: $f gains one start marker" [ "$(count_lines "$HUB7/$f" "$START")" -eq 1 ]
  check "append: $f gains one end marker" [ "$(count_lines "$HUB7/$f" "$END")" -eq 1 ]
  check "append: $f has the same block as a new file" [ "$(block_of "$HUB7/$f")" = "$REF_BLOCK" ]
  check "append: a blank line precedes the block in $f" \
    sh -c 'n="$(grep -n -x -F -e "$2" "$1" | cut -d: -f1)"; [ "$(sed -n "$((n - 1))p" "$1")" = "" ]' _ "$HUB7/$f" "$START"
  check "append: $f ends with the end marker" [ "$(tail -n 1 "$HUB7/$f")" = "$END" ]
  backup="$(find "$HUB7" -maxdepth 1 -name "$f.bak.*" | head -1)"
  check "append: one backup of $f holds the original" sh -c '[ -n "$1" ] && cmp -s "$1" "$2"' _ "$backup" "$orig"
done
check "append: CLAUDE.md gets exactly one blank line before the block" \
  [ "$(sed -n 6p "$HUB7/CLAUDE.md")" = "$START" ]

before="$(snapshot "$HUB7")"
run_init "$HUB7" --apply
check "append: second apply reports keep for CLAUDE.md" contains "$OUT" "keep    CLAUDE.md"
check "append: second apply reports keep for AGENTS.md" contains "$OUT" "keep    AGENTS.md"
check "append: second apply reports no changes" contains "$OUT" "No changes"
check "append: second apply leaves every file byte-identical" [ "$(snapshot "$HUB7")" = "$before" ]

# An outdated block (as after a template change), with text after it.
rm -f "$HUB7"/CLAUDE.md.bak.*
sed 's/Never edit code/Old wording: never edit code/' "$HUB7/CLAUDE.md" > "$WORK/c.md"
printf 'After the block.\n' >> "$WORK/c.md"
cat "$WORK/c.md" > "$HUB7/CLAUDE.md"
run_init "$HUB7"
check "dry-run says update block for an outdated block" contains "$OUT" "update block CLAUDE.md"
check "dry-run keeps the unchanged AGENTS.md" contains "$OUT" "keep    AGENTS.md"
run_init "$HUB7" --apply
check "update: CLAUDE.md keeps the text before the block" starts_with "$HUB7/CLAUDE.md" "$WORK/claude.orig"
check "update: CLAUDE.md keeps the text after the block" [ "$(tail -n 1 "$HUB7/CLAUDE.md")" = "After the block." ]
check "update: the block is current again" [ "$(block_of "$HUB7/CLAUDE.md")" = "$REF_BLOCK" ]
check "update: still one block" [ "$(count_lines "$HUB7/CLAUDE.md" "$START")" -eq 1 ]
check "update: exactly one backup, holding the outdated file" \
  sh -c 'orig="$2"; set -- "$1"/CLAUDE.md.bak.*; [ $# -eq 1 ] && cmp -s "$1" "$orig"' _ "$HUB7" "$WORK/c.md"
before="$(snapshot "$HUB7")"
run_init "$HUB7" --apply
check "update: second apply leaves the file byte-identical" [ "$(snapshot "$HUB7")" = "$before" ]
rm -f "$HUB7"/AGENTS.md.bak.*
sed 's/Never edit code/Old wording: never edit code/' "$HUB7/AGENTS.md" > "$WORK/a.md"
cat "$WORK/a.md" > "$HUB7/AGENTS.md"
run_init "$HUB7" --apply
check "update: AGENTS.md reports update block" contains "$OUT" "update block AGENTS.md"
check "update: AGENTS.md keeps the text before the block" starts_with "$HUB7/AGENTS.md" "$WORK/agents.orig"
check "update: the AGENTS.md block is current again" [ "$(block_of "$HUB7/AGENTS.md")" = "$REF_BLOCK" ]
check "update: exactly one backup of AGENTS.md, holding the outdated file" \
  sh -c 'orig="$2"; set -- "$1"/AGENTS.md.bak.*; [ $# -eq 1 ] && cmp -s "$1" "$orig"' _ "$HUB7" "$WORK/a.md"

HUB12="$(new_hub legacy)"
printf '# Hub folder\n\nThis is the Hub folder of the orca-issue-orchestrator skill. Old text.\n' > "$HUB12/CLAUDE.md"
run_init "$HUB12"
check "an unmarked text from an older init-hub gets a note" contains "$OUT" "Note: CLAUDE.md already holds the instructions an older init-hub wrote"
check "no note for an AGENTS.md that is created" sh -c '! printf "%s" "$1" | grep -q "Note: AGENTS.md"' _ "$OUT"

HUB8="$(new_hub badmarkers)"
printf '# Guide\n%s\nno end marker\n' "$START" > "$HUB8/CLAUDE.md"
before="$(snapshot "$HUB8")"
run_init "$HUB8" --apply
check "an unbalanced marker stops init-hub" [ "$CODE" -ne 0 ]
check "an unbalanced marker names the file" contains "$OUT" "CLAUDE.md"
check "an unbalanced marker leaves the Hub folder untouched" [ "$(snapshot "$HUB8")" = "$before" ]
printf '%s\n%s\n%s\n%s\n' "$START" "$END" "$START" "$END" > "$HUB8/CLAUDE.md"
before="$(snapshot "$HUB8")"
run_init "$HUB8" --apply
check "two blocks stop init-hub" [ "$CODE" -ne 0 ]
check "two blocks leave the Hub folder untouched" [ "$(snapshot "$HUB8")" = "$before" ]
printf '%s\n%s\n' "$END" "$START" > "$HUB8/CLAUDE.md"
run_init "$HUB8" --apply
check "an end marker before the start stops init-hub" [ "$CODE" -ne 0 ]

HUB9="$(new_hub fenced)"
printf '# Guide\n\n```markdown\n%s\nexample\n%s\n```\n' "$START" "$END" > "$HUB9/CLAUDE.md"
cp "$HUB9/CLAUDE.md" "$WORK/fenced.orig"
run_init "$HUB9" --apply
check "markers inside a code fence are not the block" contains "$OUT" "append block CLAUDE.md"
check "fenced markers: the example is kept" starts_with "$HUB9/CLAUDE.md" "$WORK/fenced.orig"
check "fenced markers: the block is appended" \
  sh -c '[ "$(grep -c -x -F -e "$2" "$1")" -eq 2 ] && [ "$(tail -n 1 "$1")" = "$3" ]' _ "$HUB9/CLAUDE.md" "$START" "$END"
run_init "$HUB9" --apply
check "fenced markers: second apply reports no changes" contains "$OUT" "No changes"

HUB10="$(new_hub linked)"
printf '# Guide\n\nShared text.\n' > "$HUB10/CLAUDE.md"
ln -s CLAUDE.md "$HUB10/AGENTS.md"
run_init "$HUB10" --apply
check "symlinked AGENTS.md: apply exits 0" [ "$CODE" -eq 0 ]
check "symlinked AGENTS.md is merged, not replaced" contains "$OUT" "append block AGENTS.md"
check "symlinked AGENTS.md stays a symlink" [ -L "$HUB10/AGENTS.md" ]
check "symlinked AGENTS.md: CLAUDE.md keeps its text" grep -qx 'Shared text.' "$HUB10/CLAUDE.md"
check "symlinked AGENTS.md: one block in CLAUDE.md" [ "$(count_lines "$HUB10/CLAUDE.md" "$START")" -eq 1 ]
before="$(snapshot "$HUB10")"
run_init "$HUB10" --apply
check "symlinked AGENTS.md: second apply reports no changes" contains "$OUT" "No changes"
check "symlinked AGENTS.md: second apply changes nothing" [ "$(snapshot "$HUB10")" = "$before" ]

HUB11="$(new_hub linked-out)"
printf 'outside\n' > "$WORK/outside.md"
ln -s "$WORK/outside.md" "$HUB11/CLAUDE.md"
run_init "$HUB11" --apply
check "a CLAUDE.md symlink out of the Hub folder stops init-hub" [ "$CODE" -ne 0 ]
check "the file outside the Hub folder is untouched" [ "$(cat "$WORK/outside.md")" = outside ]

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

# --- an existing JSON file that is not an object -------------------------------

HUB5="$(new_hub badjson)"
mkdir -p "$HUB5/.claude"
echo "[1]" > "$HUB5/.claude/settings.json"
before="$(snapshot "$HUB5")"
run_init "$HUB5" --apply
check "a settings.json that is not an object stops init-hub" [ "$CODE" -ne 0 ]
check "a settings.json that is not an object leaves the Hub folder untouched" [ "$(snapshot "$HUB5")" = "$before" ]
run_init "$HUB5" --apply --concurrency 120
check "--concurrency 120 passes argument checks" contains "$OUT" "not a JSON object"
run_init "$HUB5" --concurrency 0
check "--concurrency 0 is rejected" [ "$CODE" -ne 0 ]

# --- a Hub path with a dot -------------------------------------------------------

HUB4="$(new_hub dotted.hub)"
run_init "$HUB4"
check "a dotted path prints the CODEX_HOME alternative" contains "$OUT" "CODEX_HOME=$HUB4/.codex-home"

# --- a Hub folder created in the Orca app (worktree ps) ---------------------------

mkdir -p "$WORK/app-hub"
APP="$WORK/app-hub"
printf '%s\n' "$APP" >> "$ORCA_APP_FOLDERS"
run_init "$APP" --apply
check "a folder-workspace row in worktree ps is accepted" [ "$CODE" -eq 0 ]
HA="$APP/.orca-hub/hub.json"
check "app folder: hub.json hub_path is the Hub folder" jq -e --arg h "$APP" '.hub_path == $h' "$HA"
check "app folder: hub.json records orca_worktree_id" jq -e --arg id "$PS_ID" '.orca_worktree_id == $id' "$HA"
check "app folder: hub.json records orca_display_name" jq -e --arg n "$PS_NAME" '.orca_display_name == $n' "$HA"
check "app folder: the Guard hook points into the Hub folder" \
  jq -e --arg g "$APP/.orca-hub/guard.sh" 'any(.hooks.PreToolUse[]; any(.hooks[]; .command | contains($g)))' "$APP/.claude/settings.json"
run_init "$APP" --apply
check "app folder: second apply reports no changes" contains "$OUT" "No changes"

ln -s "$APP" "$WORK/app-link"
run_init "$WORK/app-link"
check "app folder through a symlink is matched by realpath" [ "$CODE" -eq 0 ]
check "app folder through a symlink plans for the path Orca holds" contains "$OUT" "plan for $APP (dry-run)"

touch "$WORK/repo-list.fail"
run_init "$APP"
check "app folder is accepted when orca repo list fails" [ "$CODE" -eq 0 ]
rm -f "$WORK/repo-list.fail"

BOTH="$(new_hub both-sources)"
printf '%s\n' "$BOTH" >> "$ORCA_APP_FOLDERS"
run_init "$BOTH" --apply
check "a folder known to both sources is accepted" [ "$CODE" -eq 0 ]
check "a folder known to both sources records orca_worktree_id from worktree ps" \
  jq -e --arg id "$PS_ID" '.orca_worktree_id == $id' "$BOTH/.orca-hub/hub.json"

mkdir -p "$WORK/ps-only-missing"
touch "$WORK/repo-list.fail"
run_init "$WORK/ps-only-missing"
check "an unknown folder with one source failing exits non-zero" [ "$CODE" -ne 0 ]
check "an unknown folder with one source failing names the failed call" contains "$OUT" "orca repo list failed (is Orca running?)"
rm -f "$WORK/repo-list.fail"

HUB6="$(new_hub both-fail)"
touch "$WORK/worktree-ps.fail"
run_init "$HUB6"
check "a repo list folder does not need worktree ps" [ "$CODE" -eq 0 ]
touch "$WORK/repo-list.fail"
run_init "$HUB6"
check "both sources failing exits non-zero" [ "$CODE" -ne 0 ]
check "both sources failing says Orca may not be running" contains "$OUT" "is Orca running?"
rm -f "$WORK/repo-list.fail" "$WORK/worktree-ps.fail"

# --- not an Orca folder workspace ------------------------------------------------

mkdir -p "$WORK/unregistered"
run_init "$WORK/unregistered" --apply
check "an unregistered folder exits non-zero" [ "$CODE" -ne 0 ]
check "an unregistered folder prints the setup command" \
  contains "$OUT" "orca project setup-existing-folder"
check "the setup command uses --kind folder" contains "$OUT" "--kind folder"
check "the refusal names both sources" sh -c 'printf "%s" "$1" | grep -q "orca repo list" && printf "%s" "$1" | grep -q "orca worktree ps"' _ "$OUT"
check "an unregistered folder gets no files" [ -z "$(ls -A "$WORK/unregistered")" ]

run_init "$WORK/missing"
check "a missing folder exits non-zero" [ "$CODE" -ne 0 ]
check "a missing folder prints the setup command" contains "$OUT" "orca project setup-existing-folder"
check "a missing folder is not created" [ ! -e "$WORK/missing" ]

run_init
check "no arguments exits non-zero with usage" sh -c '[ "$1" -ne 0 ] && printf "%s" "$2" | grep -q Usage' _ "$CODE" "$OUT"

# --- nothing outside the Hub folder ------------------------------------------------

check "nothing under the fake HOME changed" [ "$(snapshot "$FAKE_HOME")" = "$home_before" ]
check "orca was only asked to list repos and worktrees" sh -c '! grep -v -e "^repo list --json$" -e "^worktree ps --json$" "$1"' _ "$ORCA_LOG"

# --- summary ------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
