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
# Markers of the closeout and merged-PR notice comments; each makes its
# comment post once.
CLOSEOUT_MARKER="$MAPPING_MARKER-closeout"
AUDIT_MARKER="$MAPPING_MARKER-audit"

# Set to 1 by a script's --apply flag.
APPLY=0
# The authenticated gh login (gh_login). Reset here so an inherited
# environment value can never stand in for the real lookup.
_ORCA_GH_LOGIN=""

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

# lower <text>: ASCII lowercase (GitHub owner and repo names are case-insensitive).
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

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

# gh_login: the login gh is authenticated as, the only author whose marker
# comments are trusted. Looked up once per run: gh_login_load caches it in
# _ORCA_GH_LOGIN (a call inside a command substitution cannot). Returns 1 when
# gh cannot tell.
gh_login() {
  if [ -z "$_ORCA_GH_LOGIN" ]; then
    _ORCA_GH_LOGIN="$(gh api user --jq .login 2> /dev/null)" || _ORCA_GH_LOGIN=""
  fi
  [ -n "$_ORCA_GH_LOGIN" ] || return 1
  printf '%s\n' "$_ORCA_GH_LOGIN"
}

# gh_login_load: look the login up now and cache it; die when gh cannot tell.
gh_login_load() {
  _ORCA_GH_LOGIN=""
  gh_login > /dev/null || die "cannot read the authenticated gh login (gh api user); run: gh auth status"
}

# mapping_warn <owner/repo> <JSON array of {issue, why}>: one stderr line per
# ignored Mapping block.
mapping_warn() {
  local line
  while IFS= read -r line; do
    [ -z "$line" ] || note "warning: $1#$line"
  done <<EOF_WHY
$(printf '%s' "$2" | jq -r '.[] | "\(.issue): ignoring a Mapping block: \(.why)"')
EOF_WHY
}

# The in-flight search, one GraphQL page of Issues at a time, each with its
# first 100 comments (gh_in_flight fetches the rest of a longer thread).
# shellcheck disable=SC2016  # GraphQL variables, not shell ones
IN_FLIGHT_QUERY='query($q: String!, $endCursor: String) {
  search(query: $q, type: ISSUE, first: 50, after: $endCursor) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes { ... on Issue { number title url
      comments(first: 100) { totalCount nodes { author { login } body } } } }
  }
}'

# gh_in_flight <owner/repo>: JSON array of the open Issues assigned to @me
# that carry a trusted Mapping block (see mapping_latest), as
# {number, title, url, comments}. It reads every page of the search and every
# comment of each Issue. Each ignored block gets a stderr line (not with
# MAPPING_QUIET=1). Returns 1 when gh fails, answers with something that is
# not search pages, the search holds fewer Issues than it counts (GitHub
# search stops at 1000), or the login is unknown: a partial list would hide
# in-flight work and undercount concurrency.
gh_in_flight() {
  local list login scan pages n comments
  login="$(gh_login)" || return 1
  pages="$(gh api graphql --paginate -f query="$IN_FLIGHT_QUERY" \
    -f q="repo:$1 is:issue is:open assignee:@me $MAPPING_MARKER in:comments")" || return 1
  # {nodes} from every page, or {error}: never a partial list.
  list="$(printf '%s' "$pages" | jq -cs '
    if length > 0 and all(.[]; .data.search.nodes? | type == "array") then
      [.[].data.search.nodes[] | select(.number? != null)] as $nodes
      | (map(.data.search.issueCount) | max) as $count
      | if ($count | type) == "number" and $count > ($nodes | length) then
          {error: "the search returned \($nodes | length) of \($count) Issues (GitHub search stops at 1000)"}
        else {nodes: $nodes} end
    else {error: "gh answered with something that is not GraphQL search pages"} end' 2> /dev/null)" || list=""
  if [ -z "$list" ] || [ -n "$(json_get "$list" '.error')" ]; then
    note "error: cannot list every in-flight Issue of $1: $(json_get "$list" '.error' 2> /dev/null || true)"
    return 1
  fi
  list="$(json_get "$list" '.nodes' -c)"
  # A thread longer than the first page of comments: read all of it.
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    comments="$(gh api --paginate "repos/$1/issues/$n/comments?per_page=100")" || return 1
    comments="$(printf '%s' "$comments" | jq -cs 'if all(.[]; type == "array") then add // [] else error("not arrays") end
      | map({author: {login: (.user.login? // "")}, body: (.body // "")})' 2> /dev/null)" || return 1
    list="$(printf '%s' "$list" | jq -c --argjson n "$n" --argjson c "$comments" \
      'map(if .number == $n then .comments = {totalCount: ($c | length), nodes: $c} else . end)')" || return 1
  done <<EOF_LONG
$(printf '%s' "$list" | jq -r '.[] | select((.comments.totalCount // 0) > (.comments.nodes // [] | length)) | .number')
EOF_LONG
  list="$(printf '%s' "$list" | jq -c 'map(.comments = (.comments.nodes // []))')" || return 1
  # The search also hits comments that merely mention the marker, and anyone
  # can post a marker; keep only Issues with a trusted Mapping block.
  scan="$(printf '%s' "$list" | jq -ce --arg m "$MAPPING_MARKER" --arg login "$login" --arg repo "$1" \
    --arg hub "$(mapping_hub)" "$MAPPING_JQ"'
    if type == "array" then map({issue: ., scan: mapping_scan($m; $login; $repo; $hub)})
      | {issues: map(select(.scan.block != null) | .issue),
         rejects: map(.issue.number as $n | .scan.rejects[] | {issue: $n, why: .})}
    else error("not an array") end' 2> /dev/null)" || return 1
  [ "${MAPPING_QUIET:-0}" = 1 ] || mapping_warn "$1" "$(printf '%s' "$scan" | jq -c '.rejects')"
  printf '%s' "$scan" | jq -c '.issues'
}

# gh_issue_comments <owner/repo> <n>: every comment of the Issue, as a JSON
# array of {author: {login}, body}, from all REST pages. `gh issue view --json
# comments` stops at the first GraphQL page, so a Mapping or closeout block
# past comment 100 would go unseen. Returns 1 when gh fails.
gh_issue_comments() {
  local pages
  pages="$(gh api --paginate "repos/$1/issues/$2/comments?per_page=100")" || return 1
  printf '%s' "$pages" | jq -cs 'if length > 0 and all(.[]; type == "array") then add else error("not arrays") end
    | map({author: {login: (.user.login? // "")}, body: (.body // "")})' 2> /dev/null
}

# gh_issue_view <owner/repo> <n> <fields>: gh issue view --json <fields>, with
# .comments replaced by every comment (gh_issue_comments). Returns 1 when gh fails.
gh_issue_view() {
  local issue comments
  issue="$(gh issue view "$2" -R "$1" --json "$3")" || return 1
  comments="$(gh_issue_comments "$1" "$2")" || return 1
  printf '%s' "$issue" | jq -c --argjson c "$comments" '.comments = $c'
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

# A Mapping block is trusted only when its comment was posted by the
# authenticated orchestrator (gh_login) and the block names this context:
# v 1, the Issue's <owner>/<repo> and number, and the Hub's hub_id. Anyone can
# comment on a public Issue; a copied or forged block must not make closeout
# consume another Dispatch or recovery rebind to another Run.
#
# mapping_scan($m; $login; $repo; $hub) over an Issue object: {block, rejects}
# where block is the last trusted block (null if none) and rejects lists why
# every other block was ignored. Repo names compare case-insensitively, as on
# GitHub. $hub "" means no hub.json is loaded (every current script loads one):
# any non-empty hub is accepted and mapping_latest logs it.
# shellcheck disable=SC2016  # jq variables, not shell ones
MAPPING_JQ='
def mapping_scan($m; $login; $repo; $hub):
  .number as $n
  | [.comments[]? | (.author.login? // "") as $a | (.body // "")
      | scan("<!-- " + $m + " (\\{.*?\\}) -->") | .[0]
      | {a: $a, b: (try fromjson catch null)}]
  | map(.b as $b | . + {why: (
      if .a != $login then
        "posted by \(if .a == "" then "an unknown author" else .a end), not the authenticated gh login \($login)"
      elif ($b | type) != "object" then "not a JSON object"
      elif $b.v != 1 then "version \($b.v | tojson), not 1"
      elif ($b.repo | type) != "string" or ($b.repo | ascii_downcase) != ($repo | ascii_downcase) then
        "repo \($b.repo | tojson), not \($repo)"
      elif $b.issue != $n then "issue \($b.issue | tojson), not \($n)"
      elif ($b.hub | type) != "string" or ($b.hub | length) == 0 then "no hub"
      elif $hub != "" and $b.hub != $hub then "hub \($b.hub | tojson), not \($hub)"
      else null end)})
  | {block: (map(select(.why == null) | .b) | last), rejects: map(select(.why != null) | .why)};
'

# mapping_hub: the hub_id blocks must name; empty when no hub.json is loaded.
mapping_hub() {
  if [ -n "${HUB_JSON:-}" ]; then hub_id; fi
}

# mapping_latest <issue json with .number, .comments[]> <owner/repo>: the last
# trusted Mapping block in comment order, as compact JSON; empty when there is
# none. After a retry an Issue has several blocks; the latest is current. Each
# ignored block gets a line on stderr (not with MAPPING_QUIET=1). Returns 1
# when the login is unknown or the comments cannot be read.
mapping_latest() {
  local login hub scan block n
  login="$(gh_login)" || { note "error: cannot read the authenticated gh login; trusting no Mapping block"; return 1; }
  hub="$(mapping_hub)"
  scan="$(printf '%s' "$1" | jq -c --arg m "$MAPPING_MARKER" --arg login "$login" --arg repo "$2" \
    --arg hub "$hub" "$MAPPING_JQ"'mapping_scan($m; $login; $repo; $hub)')" || return 1
  n="$(json_get "$1" '.number')"
  [ "${MAPPING_QUIET:-0}" = 1 ] ||
    mapping_warn "$2" "$(printf '%s' "$scan" | jq -c --argjson n "${n:-0}" '[.rejects[] | {issue: $n, why: .}]')"
  block="$(json_get "$scan" '.block' -c)"
  [ -z "$block" ] || [ -n "$hub" ] ||
    note "note: no hub.json in use; the Mapping block on $2#$n names hub $(json_get "$block" '.hub')"
  printf '%s' "$block"
}

# has_marker_comment <json with .comments[]> <marker> <field> <value>: true
# when a comment by the authenticated orchestrator holds a
# `<!-- <marker> {...} -->` block whose <field> is <value> (compared as text)
# and whose hub is this Hub's hub_id (any non-empty hub when no hub.json is
# loaded, as for Mapping blocks). Only the parsed block counts: prose around
# it that names another id does not. Other authors' markers, and markers of
# another Hub or with no hub, are ignored.
has_marker_comment() {
  local login
  login="$(gh_login)" || return 1
  # shellcheck disable=SC2016  # jq variables
  printf '%s' "$1" | jq -e --arg login "$login" --arg m "$2" --arg f "$3" --arg v "$4" --arg hub "$(mapping_hub)" '
    any(.comments[]? | select(.author.login? == $login) | (.body // "")
      | scan("<!-- " + $m + " (\\{.*?\\}) -->") | .[0] | (try fromjson catch null);
      type == "object" and has($f) and (.[$f] | tostring) == $v
      and (.hub | type) == "string" and (.hub | length) > 0 and ($hub == "" or .hub == $hub))' > /dev/null 2>&1
}

# marker_fragment <text>: print the first orchestrator marker opening in the
# text (`<!--` then any orca-issue-orchestrator marker, any spacing) and
# return 0; return 1 when there is none. Worker-derived text (the worker_done
# body, filesModified) must never carry one into a comment the orchestrator
# posts: mapping_latest trusts every block in the orchestrator's comments.
marker_fragment() {
  printf '%s' "$1" | grep -Eo -m1 "<!--[[:space:]]*${MAPPING_MARKER}[A-Za-z0-9_-]*" | head -1 | grep .
}

# --- local paths ------------------------------------------------------------------

# Public comments must never carry a local path. LOCAL_PATH_RE (a jq regex)
# matches an absolute path under a common local root (/Users, /home, /tmp,
# /private, /var, /opt, /srv, /mnt, /root, /Volumes, and the /path placeholder) or a <repo-id>::/<path> worktree
# id (not an IPv6 prefix such as ::/0), up to the next space, quote, bracket, or backtick (trailing sentence
# punctuation excluded). local_path_scan adds the Hub folder, its hub.json
# hub_path, and $HOME. tests/helpers.sh uses the same functions, so the tests
# and the guard cannot drift apart.
_LP_STOP="\\s\`'\"<>()\\[\\]"
_LP_TAIL="[^$_LP_STOP]*?(?=[.,;:!?]*(?:[$_LP_STOP]|\$))"
LOCAL_PATH_RE="(?<![A-Za-z0-9_.-])/(?:path|Users|home|tmp|private|var|opt|srv|mnt|root|Volumes)/$_LP_TAIL|[^$_LP_STOP]*::/(?![0-9])$_LP_TAIL"

# local_path_scan <find|redact> <text>: find prints the first local path in
# the text (nothing when there is none); redact prints the text with each one
# replaced by <local-path>.
local_path_scan() {
  local hub_path=""
  # An unreadable hub.json fails the scan (the caller then refuses), never
  # drops hub_path from it.
  if [ -n "${HUB_JSON:-}" ]; then hub_path="$(hub_get '.hub_path // empty')" || return 1; fi
  # shellcheck disable=SC2016  # jq variables
  printf '%s' "$2" | jq -Rrs --arg mode "$1" --arg re "$LOCAL_PATH_RE" --arg tail "$_LP_TAIL" \
    --arg lits "$(printf '%s\n' "${HUB_DIR:-}" "$hub_path" "${HOME:-}")" '
    ([$lits | split("\n")[] | select(startswith("/") and length > 1)
      | gsub("(?<c>[.^$|?*+(){}\\[\\]\\\\])"; "\\\(.c)") + $tail] + [$re] | join("|")) as $all
    | if $mode == "redact" then gsub($all; "<local-path>")
      else (first(match($all; "g").string) // empty) end'
}

# local_path_fragment <text>: print the first local path in the text and
# return 0; return 1 when there is none. A text that cannot be scanned counts
# as holding one.
local_path_fragment() {
  local frag
  frag="$(local_path_scan find "$1")" || frag="(the text could not be scanned)"
  [ -n "$frag" ] || return 1
  printf '%s\n' "$frag"
}

# redact_local_paths <text>: the text with each local path replaced by <local-path>.
redact_local_paths() { local_path_scan redact "$1"; }

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

# orca_worktree <worktree-id>: the worktree list row as compact JSON, empty if
# absent. Returns 1, with the reason and the raw answer on stderr, when
# `orca worktree list` fails or answers anything but {ok: true} with a
# result.worktrees array: an error envelope must not pass for "not listed".
orca_worktree() {
  local list
  list="$(orca worktree list --json)" || {
    note "orca worktree list failed"
    return 1
  }
  printf '%s' "$list" | jq -e 'select(.ok == true and (.result.worktrees | type) == "array")' > /dev/null 2>&1 || {
    printf '%s\n' "$list" >&2
    note "orca worktree list answered no {ok: true} list of worktrees (above)"
    return 1
  }
  printf '%s' "$list" | jq -c --arg id "$1" 'first(.result.worktrees[] | select(.id == $id)) // empty'
}

# orca_workers <run-id>: every worker-list row of the Run as one JSON array,
# following page.nextCursor. Returns 1, with the reason on stderr, when
# worker-list fails, answers anything but {ok: true} with result.workers[] and
# result.page, says hasMore without a nextCursor, or has more pages than
# ORCA_WORKER_PAGES_MAX (default 1000): a partial list must not pass for all.
orca_workers() {
  local acc='[]' cursor="" page pages=0 max="${ORCA_WORKER_PAGES_MAX:-1000}"
  printf '%s' "$max" | grep -Eq '^[1-9][0-9]*$' || max=1000
  while :; do
    pages=$((pages + 1))
    if [ "$pages" -gt "$max" ]; then
      printf 'worker-list --run %s: still hasMore after %s pages; giving up\n' "$1" "$max" >&2
      return 1
    fi
    if [ -n "$cursor" ]; then
      page="$(orca orchestration worker-list --run "$1" --limit 100 --cursor "$cursor" --json)" || return 1
    else
      page="$(orca orchestration worker-list --run "$1" --limit 100 --json)" || return 1
    fi
    if ! printf '%s' "$page" | jq -e '.ok == true and (.result.workers | type) == "array"
        and (.result.page | type) == "object"' > /dev/null 2>&1; then
      printf 'worker-list --run %s answered no {ok: true} page of workers:\n%s\n' "$1" "$page" >&2
      return 1
    fi
    acc="$(printf '%s' "$page" | jq -c --argjson acc "$acc" '$acc + .result.workers')" || return 1
    printf '%s' "$page" | jq -e '.result.page.hasMore == true' > /dev/null || break
    cursor="$(json_get "$page" '.result.page.nextCursor | strings')"
    if [ -z "$cursor" ]; then
      printf 'worker-list --run %s: page %s says hasMore with no nextCursor; giving up\n' "$1" "$pages" >&2
      return 1
    fi
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
