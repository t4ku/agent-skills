#!/usr/bin/env bash
# orca-issue-orchestrator Guard for Claude Code (PreToolUse hook).
# guard-version: 1
#
# Judges only when $CLAUDE_PROJECT_DIR exactly equals hub_path in
# $CLAUDE_PROJECT_DIR/.orca-hub/hub.json; any other session gets no output and
# exit 0. In the Hub folder:
#   - Edit / Write / NotebookEdit: allowed only when the realpath of the target
#     is under docs/, research/, tmp/, or .orca-hub/ of the Hub folder.
#   - Bash: the command is split on && || ; | (and any & / newline); the first token
#     of every segment must be on the allowlist (plus bash_allow[] from
#     hub.json). A segment containing > is denied.
#   - Every other tool (Agent, Read, ...) is left alone.
# A denial is exit 0 with hookSpecificOutput.permissionDecision "deny".
#
# Dependencies: bash, jq, realpath, coreutils. Config schema:
# references/hub-json.md. Tests: tests/guard.test.sh.

set -u
set -f  # word lists below are split unquoted; never glob them

REASON='Editing code is forbidden in the orchestrator. Create a Task with orca orchestration and delegate it (see /orca-issue-orchestrator).'
ALLOWED_DIRS='docs research tmp .orca-hub'
ALLOWED_COMMANDS='orca gh git ls cat rg grep jq head tail wc find echo cd pwd test [ true'
ALLOWED_GIT='status log diff show branch worktree remote rev-parse ls-files fetch'

hub="${CLAUDE_PROJECT_DIR:-}"
[ -n "$hub" ] || exit 0
config="$hub/.orca-hub/hub.json"
[ -f "$config" ] || exit 0

deny() {
  local reason="$REASON"
  if [ -n "${1:-}" ]; then
    reason="$REASON Blocked segment: $1"
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg r "$reason" \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  else
    # Without jq the Hub folder cannot be confirmed; fail closed. The fixed reason has
    # no characters that need JSON escaping; a token might, so it is dropped.
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$REASON"
  fi
  exit 0
}

command -v jq >/dev/null 2>&1 || deny
hub_path="$(jq -r '.hub_path // empty' "$config" 2>/dev/null)" || exit 0
[ "$hub_path" = "$hub" ] || exit 0

# From here on this is the Orchestrator session: fail closed.
input="$(cat)"
tool="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)" || deny

# field <jq path>: print a string field of the hook input, or nothing.
field() {
  printf '%s' "$input" | jq -r "$1 // empty"
}

# resolve_path <path>: print the physical absolute path. Missing trailing
# components are appended to the realpath of the deepest existing ancestor;
# a ".." among them cannot be resolved safely and fails.
resolve_path() {
  local path="$1" rest="" base name
  case "$path" in
    /*) ;;
    *) path="$hub/$path" ;;
  esac
  while [ ! -e "$path" ] && [ ! -L "$path" ]; do
    name="$(basename -- "$path")"
    case "$name" in
      ..) return 1 ;;
      .) ;;
      *) rest="/$name$rest" ;;
    esac
    path="$(dirname -- "$path")"
  done
  base="$(realpath -- "$path" 2>/dev/null)" || return 1
  printf '%s%s\n' "${base%/}" "$rest"
}

check_path() {
  local target="$1" real hub_real d
  [ -n "$target" ] || deny
  real="$(resolve_path "$target")" || deny
  hub_real="$(realpath -- "$hub" 2>/dev/null)" || deny
  for d in $ALLOWED_DIRS; do
    case "$real" in
      "$hub_real/$d/"?*) exit 0 ;;
    esac
  done
  deny
}

# in_list <word> <space-separated list>
in_list() {
  local w
  for w in $2; do
    [ "$w" = "$1" ] && return 0
  done
  return 1
}

extra_allow="$(jq -r '.bash_allow[]? // empty' "$config" 2>/dev/null | tr '\n' ' ')"

# check_segment <segment>: deny unless the segment may run.
check_segment() {
  local seg="$1" first second
  case "$seg" in
    *'>'*) deny '>' ;;
  esac
  read -r first second _ <<< "$seg"
  [ -n "$first" ] || return 0
  if [ "$first" = git ]; then
    in_list "${second:-}" "$ALLOWED_GIT" && return 0
    deny "git${second:+ $second}"
  fi
  in_list "$first" "$ALLOWED_COMMANDS" && return 0
  in_list "$first" "$extra_allow" && return 0
  case "$(basename -- "$first")" in
    issue-*.sh|frontier.sh) return 0 ;;
  esac
  deny "$first"
}

# check_command <command>: split on unquoted ; & | and newlines (which covers
# && and ||) and check every segment. Quote state tracks '...', "..." and
# $'...' (where a backslash escapes the closing quote). Subshells are not
# parsed.
check_command() {
  local cmd="$1" seg="" quote="" c i
  for ((i = 0; i < ${#cmd}; i++)); do
    c="${cmd:i:1}"
    if [ -n "$quote" ]; then
      if [ "$quote" != "'" ] && [ "$c" = "\\" ]; then
        seg="$seg$c${cmd:i+1:1}"
        i=$((i + 1))
        continue
      fi
      [ "$c" = "${quote#$}" ] && quote=""
      seg="$seg$c"
      continue
    fi
    case "$c" in
      '$')
        if [ "${cmd:i+1:1}" = "'" ]; then
          quote="\$'"; seg="$seg\$'"; i=$((i + 1))
        else
          seg="$seg$c"
        fi ;;
      "'"|'"') quote="$c"; seg="$seg$c" ;;
      "\\") seg="$seg$c${cmd:i+1:1}"; i=$((i + 1)) ;;
      ';'|'&'|'|'|$'\n') check_segment "$seg"; seg="" ;;
      *) seg="$seg$c" ;;
    esac
  done
  check_segment "$seg"
}

case "$tool" in
  Edit|Write)
    check_path "$(field .tool_input.file_path)" ;;
  NotebookEdit)
    check_path "$(field .tool_input.notebook_path)" ;;
  Bash)
    check_command "$(field .tool_input.command)" ;;
  '')
    deny ;;
esac
exit 0
