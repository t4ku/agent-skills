#!/usr/bin/env bash
# Shared helpers for the Orchestrator commands (frontier.sh, issue-*.sh).
#
# Source it; it defines functions and constants only. Centralises:
#   - reading .orca-hub/hub.json
#   - gh / orca JSON extraction
#   - the dry-run / --apply wrapper
#   - the AI disclaimer every comment starts with
#   - resolving <owner>/<repo> to an Orca repo selector
# Dependencies: bash (3.2+), jq, gh, orca, coreutils.

# shellcheck disable=SC2034  # constants are used by the scripts that source this file
DISCLAIMER='> *Posted by an AI orchestrator.*'
# Marker of the Mapping comment's machine-readable block; also the search term
# that finds in-flight Issues.
MAPPING_MARKER='orca-issue-orchestrator'

# Set to 1 by a script's --apply flag.
APPLY=0

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

note() { printf '%s\n' "$*" >&2; }

# --- hub.json ---------------------------------------------------------------

# hub_load <hub-dir>: validate <hub-dir>/.orca-hub/hub.json; set HUB_DIR
# (absolute, symlinks resolved) and HUB_JSON.
hub_load() {
  HUB_DIR="$(cd "$1" 2> /dev/null && pwd -P)" || die "no Hub folder at $1"
  HUB_JSON="$HUB_DIR/.orca-hub/hub.json"
  [ -f "$HUB_JSON" ] || die "no Hub config at $HUB_JSON (run init-hub, or pass --hub <hub-dir>)"
  jq -e '(.hub_id | type == "string" and length > 0) and (.repos | type == "array")' "$HUB_JSON" > /dev/null 2>&1 ||
    die "$HUB_JSON needs a string hub_id and a repos[] array"
}

# hub_get <jq filter> [jq args...]: raw output of a filter over hub.json.
hub_get() {
  local filter="$1"
  shift
  jq -r "$@" "$filter" "$HUB_JSON"
}

hub_id() { hub_get '.hub_id'; }
hub_concurrency() { hub_get '.concurrency // 1'; }
hub_repos() { hub_get '.repos[].name'; }

# hub_repo <owner/repo>: the repos[] entry as compact JSON, empty if absent.
hub_repo() {
  jq -c --arg r "$1" 'first(.repos[] | select(.name == $r)) // empty' "$HUB_JSON"
}

# --- JSON extraction ----------------------------------------------------------

# json_get <json> <jq filter> [jq args...]: raw output, "null" becomes empty.
json_get() {
  local json="$1" filter="$2"
  shift 2
  printf '%s' "$json" | jq -r "$@" "($filter) // empty"
}

# --- dry-run / --apply ----------------------------------------------------------

# quote_word <word>: shell-quote a word for display. Words made only of safe
# characters, plus <placeholder> tokens, are printed as they are.
quote_word() {
  local bare safe='^[A-Za-z0-9_./:@=,+%-]*$'
  bare="$(printf '%s' "$1" | sed 's/<[a-z_]*>//g')"
  if [ -n "$1" ] && [[ "$bare" =~ $safe ]]; then
    printf '%s' "$1"
  else
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
  fi
}

# print_cmd <argv...>: print a command on one line, shell-quoted.
print_cmd() {
  local out="" word
  for word in "$@"; do
    out="$out${out:+ }$(quote_word "$word")"
  done
  printf '%s\n' "$out"
}

# print_cmd_json <JSON array of words>: print_cmd for an argv held as JSON.
print_cmd_json() {
  local words=() word
  while IFS= read -r word; do
    words+=("$word")
  done <<EOF_WORDS
$(printf '%s' "$1" | jq -r '.[]')
EOF_WORDS
  print_cmd "${words[@]}"
}

# mutate <argv...>: print the command; run it only under --apply, capturing
# its stdout in MUTATE_OUT. Returns the command's status (0 in dry-run).
mutate() {
  MUTATE_OUT=""
  print_cmd "$@"
  if [ "$APPLY" -eq 1 ]; then
    MUTATE_OUT="$("$@")"
  fi
}

# --- gh -------------------------------------------------------------------------

# gh_default_branch <owner/repo>
gh_default_branch() {
  gh repo view "$1" --json defaultBranchRef | jq -r '.defaultBranchRef.name // empty'
}

# gh_in_flight <owner/repo>: JSON array of the open Issues assigned to @me
# that carry a Mapping block, as {number, title, url, comments}. Returns 1 when
# gh fails or answers with something that is not a JSON array.
gh_in_flight() {
  local list
  list="$(gh issue list -R "$1" --assignee @me --state open \
    --search "$MAPPING_MARKER in:comments" --json number,title,url,comments --limit 100)" || return 1
  # The search also hits comments that merely mention the marker; keep only
  # Issues with a real Mapping block.
  printf '%s' "$list" | jq -ce --arg m "<!-- $MAPPING_MARKER {" \
    'if type == "array" then map(select(any(.comments[]?; .body | contains($m)))) else error("not an array") end' \
    2> /dev/null || return 1
}

# gh_in_flight_count: gh_in_flight summed over every repo in hub.json. Prints
# nothing and returns 1 on failure; callers must treat that as a refusal (it
# runs in a command substitution).
gh_in_flight_count() {
  local repo total=0 n
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    n="$(gh_in_flight "$repo" | jq 'length')" || return 1
    case "$n" in '' | *[!0-9]*) return 1 ;; esac
    total=$((total + n))
  done <<EOF_REPOS
$(hub_repos)
EOF_REPOS
  printf '%s\n' "$total"
}

# --- Mapping comment ------------------------------------------------------------

# mapping_latest <json with .comments[]>: the last Mapping block in comment
# order, as compact JSON; empty when there is none. After a retry an Issue has
# several blocks; the latest is current.
mapping_latest() {
  printf '%s' "$1" | jq -c --arg m "$MAPPING_MARKER" '
    [.comments[]?.body // empty
      | scan("<!-- " + $m + " (\\{.*?\\}) -->") | .[0]
      | (try fromjson catch empty) | select(type == "object")]
    | last // empty'
}

# has_local_path <text>: true when the text holds the Hub folder path, its
# hub.json hub_path, the home directory, or a <repo-id>::/<path> worktree id.
# Public comments must never carry one.
has_local_path() {
  local hub_path
  hub_path="$(hub_get '.hub_path // empty')"
  case "$1" in
    *::/* | *"$HUB_DIR"* | *"${hub_path:-$HUB_DIR}"* | *"${HOME:-$HUB_DIR}"*) return 0 ;;
  esac
  return 1
}

# read_input <file|->: print a file, or stdin for "-".
read_input() {
  if [ "$1" = "-" ]; then
    cat
  else
    [ -f "$1" ] || die "no such file: $1"
    cat "$1"
  fi
}

# --- orca -----------------------------------------------------------------------

# orca_repo_selector <owner/repo>: id:<repo-id> of the Orca repo whose
# gitRemoteIdentity.canonicalKey is github.com/<owner>/<repo>.
orca_repo_selector() {
  local id
  id="$(orca repo list --json | jq -r --arg k "github.com/$1" \
    'first(.result.repos[]? | select(.gitRemoteIdentity.canonicalKey? == $k) | .id) // empty')"
  [ -n "$id" ] || return 1
  printf 'id:%s\n' "$id"
}

# orca_bound_run: id of the Run bound to this coordinator terminal, empty if none.
orca_bound_run() {
  orca orchestration run-current --json | jq -r '.result.run.id // empty'
}

# orca_worktree <worktree-id>: the worktree list row as compact JSON, empty if absent.
orca_worktree() {
  orca worktree list --json | jq -c --arg id "$1" 'first(.result.worktrees[]? | select(.id == $id)) // empty'
}

# orca_workers <run-id>: every worker-list row of the Run as one JSON array,
# following page.nextCursor. Returns 1 when worker-list fails.
orca_workers() {
  local acc='[]' cursor="" page
  while :; do
    if [ -n "$cursor" ]; then
      page="$(orca orchestration worker-list --run "$1" --limit 100 --cursor "$cursor" --json)" || return 1
    else
      page="$(orca orchestration worker-list --run "$1" --limit 100 --json)" || return 1
    fi
    acc="$(printf '%s' "$page" | jq -c --argjson acc "$acc" '$acc + (.result.workers // [])')" || return 1
    cursor="$(json_get "$page" 'select(.result.page.hasMore == true) | .result.page.nextCursor')"
    [ -n "$cursor" ] || break
  done
  printf '%s\n' "$acc"
}

# --- naming -----------------------------------------------------------------------

# slugify <title>: about three lowercase ASCII words joined by "-".
slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' ' ' |
    awk '{ out = ""; for (i = 1; i <= NF && i <= 3; i++) out = out (i > 1 ? "-" : "") $i; print out }'
}

# worktree_name <n> <title>: issue-<n>-<slug>, or issue-<n> when the title has no ASCII word.
worktree_name() {
  local slug
  slug="$(slugify "$2")"
  if [ -n "$slug" ]; then printf 'issue-%s-%s\n' "$1" "$slug"; else printf 'issue-%s\n' "$1"; fi
}
