#!/usr/bin/env bash
# Write a Worker's outcome back to its GitHub Issue.
#
# Usage:
#   issue-closeout.sh <owner/repo> <n> <succeeded|failed> <summary-file|-> [--apply]
#                     [--pr <url>] [--files <a,b,...>] [--needs <text>] [--evidence <text>]
#                     [--redact] [--hub <hub-dir>]
#
# <summary-file> is either the `orca orchestration check --json` output that
# holds the worker_done (heartbeats and other Dispatches are ignored; the
# Dispatch is the one in the Issue's latest Mapping block), or a plain-text
# summary the Orchestrator wrote. "-" reads stdin. Only Mapping blocks posted
# by the authenticated gh login that name this repo, Issue, and Hub count.
#
#   succeeded  Comment the PR link, the summary, and the files modified.
#              Labels and assignee are untouched.
#   failed     Add `needs-info` (removing `ready-for-agent`), remove the
#              assignee, then post the failed-report template.
#
# Either way it prints, and never runs, `worker-release`. It never closes the
# Issue and never runs `task-update`. Without --apply nothing changes: every
# gh command that would change state is printed, in order.
#   --pr        The PR URL or number (default: the first PR URL of this repo
#               in the summary, else the open PR whose head is the Mapping
#               branch). Whatever its source, the PR must be OPEN, in this
#               repo, and have the Mapping branch as its head.
#   --files     Files modified, comma-separated (default: the worker_done
#               payload's filesModified). succeeded needs at least one.
#   --needs     failed only, required with --apply: what a human must supply
#   --evidence  failed only: the evidence line (default: where Orca keeps the
#               Worker's output)
#   --redact    Replace each local path in the comment with <local-path>.
#               Without it a comment holding one (/Users/..., /tmp/...,
#               /var/..., the Hub folder, $HOME, a ::/ worktree id) is refused.
#   --hub       Hub folder (default: $CLAUDE_PROJECT_DIR, else the current directory)
#
# Exit codes: 0 done (or planned, or already closed out), 1 refused / error.

# Backticks in single-quoted strings are Markdown for the comments.
# shellcheck disable=SC2016

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh disable=SC1091
. "$SCRIPT_DIR/lib.sh"

hub_arg="${CLAUDE_PROJECT_DIR:-$PWD}"
pr_url=""
files_arg=""
needs=""
evidence=""
redact=0
positional=()

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --redact) redact=1; shift ;;
    --hub) [ $# -ge 2 ] || die "--hub needs a directory"; hub_arg="$2"; shift 2 ;;
    --pr) [ $# -ge 2 ] || die "--pr needs a URL"; pr_url="$2"; shift 2 ;;
    --files) [ $# -ge 2 ] || die "--files needs a list"; files_arg="$2"; shift 2 ;;
    --needs) [ $# -ge 2 ] || die "--needs needs a text"; needs="$2"; shift 2 ;;
    --evidence) [ $# -ge 2 ] || die "--evidence needs a text"; evidence="$2"; shift 2 ;;
    -h | --help) sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -?*) die "unknown option: $1" ;;
    *) positional+=("$1"); shift ;;
  esac
done

[ "${#positional[@]}" -eq 4 ] ||
  die "usage: issue-closeout.sh <owner/repo> <n> <succeeded|failed> <summary-file|-> [--apply] [--pr <url>] [--files <list>] [--needs <text>] [--evidence <text>] [--redact] [--hub <hub-dir>]"
repo="${positional[0]}"
number="${positional[1]}"
outcome="${positional[2]}"
summary_src="${positional[3]}"
printf '%s' "$repo" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || die "repo must be <owner>/<repo>: $repo"
printf '%s' "$number" | grep -Eq '^[1-9][0-9]*$' || die "Issue number must be a positive integer: $number"
case "$outcome" in succeeded | failed) ;; *) die "outcome must be succeeded or failed: $outcome" ;; esac

hub_load "$hub_arg"
# Only the authenticated orchestrator's marker comments are trusted.
gh_login_load
[ -n "$(hub_repo "$repo")" ] || die "$repo is not in $HUB_JSON repos[]"

if [ "$APPLY" -eq 1 ]; then mode="apply"; else mode="dry-run; add --apply to act"; fi

# --- The Issue and its latest Mapping block ---------------------------------------

issue="$(gh issue view "$number" -R "$repo" --json number,title,state,url,labels,comments)" ||
  die "cannot read $repo#$number"
block="$(mapping_latest "$issue" "$repo")" || die "cannot read the Mapping blocks on $repo#$number"
[ -n "$block" ] || die "$repo#$number has no Mapping comment; nothing to close out"
dispatch_id="$(json_get "$block" '.dispatch_id')"
branch="$(json_get "$block" '.branch')"
[ -n "$dispatch_id" ] || die "the latest Mapping block on $repo#$number has no dispatch_id"
# The worktree as dispatched, from the block; never recomputed from the title,
# which may have changed since. Blocks older than the worktree field name the
# branch, which Orca derived from the worktree name.
name="$(json_get "$block" '.worktree | strings')"
[ -n "$name" ] || name="$branch"

release_cmd() {
  printf '\n# Release the Worker'"'"'s terminal (run it yourself; this script never does)\n'
  print_cmd orca orchestration worker-release --dispatch "$dispatch_id" --json
  printf 'It exits 0 even when the resource stays external / retained (a terminal from an\n'
  printf 'earlier failed attempt): read the state it reports; that is not a failure.\n'
  printf 'The worktree is kept. Never run task-update; the worker_done settled the Task.\n'
}

printf 'Closeout for %s#%s, Dispatch %s, %s (%s):\n\n' "$repo" "$number" "$dispatch_id" "$outcome" "$mode"

# Post once per Dispatch: a rerun (even after the PR merged) changes nothing.
if has_marker_comment "$issue" "$CLOSEOUT_MARKER" dispatch_id "$dispatch_id"; then
  printf 'A closeout comment for Dispatch %s is already on the Issue; changing nothing.\n' "$dispatch_id"
  release_cmd
  exit 0
fi

# --- The summary: a check --json batch, or plain text -------------------------------

input="$(read_input "$summary_src")"
files_json='[]'
report_path=""
if printf '%s' "$input" | jq -e '.result.messages | type == "array"' > /dev/null 2>&1; then
  # Ignore heartbeats and every other Dispatch; the last worker_done for ours wins.
  done_msg="$(printf '%s' "$input" | jq -c --arg d "$dispatch_id" '
    [.result.messages[]
      | select(.type == "worker_done")
      | .payload |= (if type == "string" then (try fromjson catch {}) else (. // {}) end)
      | select(.payload.dispatchId? == $d)]
    | last // empty')"
  [ -n "$done_msg" ] || die "the batch holds no worker_done for Dispatch $dispatch_id (the latest Mapping block on $repo#$number)"
  reported="$(json_get "$done_msg" '.payload.outcome')"
  [ "$reported" = "$outcome" ] ||
    die "the worker_done for $dispatch_id reports outcome '${reported:-none}', not '$outcome'"
  summary="$(json_get "$done_msg" '.body')"
  files_json="$(printf '%s' "$done_msg" | jq -c '[.payload.filesModified[]? | strings]')"
  report_path="$(json_get "$done_msg" '.payload.reportPath')"
else
  summary="$input"
fi
summary="$(printf '%s' "$summary" | sed -e 's/[[:space:]]*$//')"
[ -n "$summary" ] || die "the summary is empty"
if [ -n "$files_arg" ]; then
  files_json="$(printf '%s' "$files_arg" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')"
fi

# --- The comment ---------------------------------------------------------------------

closeout_block="$(jq -cn --arg d "$dispatch_id" --arg o "$outcome" '{v: 1, dispatch_id: $d, outcome: $o}')"

# validate_pr <url|number> <source>: resolve the PR with gh pr view and refuse
# unless it is OPEN, in $repo, and its head is the Mapping $branch of $repo
# itself (not a fork). Reads $repo and $branch; sets pr_url to the PR's
# canonical URL.
validate_pr() {
  local ref="$1" src="$2" n pr_repo view state head head_repo cross
  case "$ref" in
    https://github.com/*/*/pull/*)
      pr_repo="$(printf '%s' "$ref" | sed -E 's#^https://github\.com/([^/]+/[^/]+)/pull/.*#\1#')"
      n="$(printf '%s' "$ref" | sed -E 's#^https://github\.com/[^/]+/[^/]+/pull/([0-9]+).*#\1#')"
      ;;
    *) pr_repo="$repo"; n="$ref" ;;
  esac
  printf '%s' "$n" | grep -Eq '^[1-9][0-9]*$' || die "the PR ($src) is not a PR URL or number: $ref"
  [ "$(lower "$pr_repo")" = "$(lower "$repo")" ] ||
    die "the PR ($src) $ref is in $pr_repo, not $repo; refusing a succeeded closeout"
  view="$(gh pr view "$n" -R "$repo" --json number,state,headRefName,headRepository,headRepositoryOwner,isCrossRepository,url)" ||
    die "cannot read PR #$n of $repo ($src); refusing a succeeded closeout"
  state="$(json_get "$view" '.state')"
  head="$(json_get "$view" '.headRefName')"
  head_repo="$(json_get "$view" '"\(.headRepositoryOwner.login // "?")/\(.headRepository.name // "?")"')"
  cross="$(json_get "$view" '.isCrossRepository | tostring')"
  pr_url="$(json_get "$view" '.url')"
  [ "$(lower "$pr_url")" = "$(lower "https://github.com/$repo/pull/$n")" ] ||
    die "PR #$n of $repo ($src) answers with URL ${pr_url:-none}, not https://github.com/$repo/pull/$n (renamed or transferred repo, or another host?); refusing a succeeded closeout"
  [ "$state" = "OPEN" ] ||
    die "PR #$n of $repo ($src) is ${state:-in an unknown state}, not OPEN; success needs an open PR"
  [ "$cross" = "false" ] && [ "$(lower "$head_repo")" = "$(lower "$repo")" ] ||
    die "PR #$n of $repo ($src) comes from $head_repo, not $repo; refusing a succeeded closeout"
  [ -n "$branch" ] && [ "$head" = "$branch" ] ||
    die "PR #$n of $repo ($src) has head branch '${head:-?}', not the Mapping branch '${branch:-?}'; refusing a succeeded closeout"
}

if [ "$outcome" = "succeeded" ]; then
  [ "$(printf '%s' "$files_json" | jq 'length')" -gt 0 ] ||
    die "a succeeded closeout needs the files modified: the worker_done has no filesModified (or the summary is plain text); pass --files <a,b,...>"
  if [ -n "$pr_url" ]; then
    pr_src="--pr"
  else
    repo_re="$(printf '%s' "$repo" | sed 's/[.]/\\./g')"
    pr_url="$(printf '%s\n' "$summary" | grep -Eo "https://github\.com/$repo_re/pull/[0-9]+" | head -1)"
    pr_src="the summary"
  fi
  if [ -z "$pr_url" ] && [ -n "$branch" ]; then
    prs="$(gh pr list -R "$repo" --head "$branch" --state open --json number,url,state,headRefName)" ||
      die "cannot list the PRs of $repo"
    pr_url="$(json_get "$prs" 'first(.[] | select(.headRefName == $b and .state == "OPEN") | .url)' --arg b "$branch")"
    pr_src="the open PR from branch $branch"
  fi
  [ -n "$pr_url" ] || die "success needs an open PR: none in the summary, none open from branch ${branch:-?}; pass --pr <url>"
  validate_pr "$pr_url" "$pr_src"
  body="$(
    printf '%s\n\n' "$DISCLAIMER"
    printf '## Worker report: succeeded\n\n'
    printf 'Pull request: %s\n\n' "$pr_url"
    printf '%s\n' "$summary"
    printf '\n**Files modified:**\n'
    printf '%s' "$files_json" | jq -r '.[] | "- `" + . + "`"'
    printf '\nWorktree `%s` (branch `%s`) is kept for review.\n\n' "$name" "$branch"
    printf '<!-- %s %s -->\n' "$CLOSEOUT_MARKER" "$closeout_block"
  )"
else
  if [ -z "$needs" ]; then
    [ "$APPLY" -eq 0 ] || die "a failed closeout needs --needs <what a human must supply>"
    needs='<what a human must supply: pass --needs>'
  fi
  if [ -z "$evidence" ]; then
    # reportPath is a local path: name that it exists, never print it.
    evidence="The Worker's output is archived in Orca under Dispatch \`$dispatch_id\`"
    [ -z "$report_path" ] || evidence="$evidence, with a report file"
    evidence="$evidence (\`orca orchestration worker-read --dispatch $dispatch_id\`)."
  fi
  body="$(
    printf '%s\n\n' "$DISCLAIMER"
    printf '## Worker report: failed\n\n'
    printf '**What was attempted:** %s\n\n' "$summary"
    printf '**Evidence:** %s\n\n' "$evidence"
    printf '**What is needed from a human:** %s\n\n' "$needs"
    printf 'Worktree `%s` (branch `%s`) is kept for inspection.\n\n' "$name" "$branch"
    printf '<!-- %s %s -->\n' "$CLOSEOUT_MARKER" "$closeout_block"
  )"
fi

# Every string in the body (summary, evidence, files, worktree and branch
# names) is checked before anything changes.
if frag="$(local_path_fragment "$body")"; then
  [ "$redact" -eq 1 ] ||
    die "refusing to post: the comment would contain the local path $frag; rewrite the summary, --evidence, or --files, or pass --redact"
  body="$(redact_local_paths "$body")" || die "cannot redact the local paths; nothing was done"
  if frag="$(local_path_fragment "$body")"; then die "a local path survived --redact: $frag; nothing was done"; fi
  note "note: --redact replaced each local path in the comment with <local-path>"
fi

if [ "$outcome" = "failed" ]; then
  # Label first: if the unassign then fails, the Issue is still out of the Frontier.
  printf '# 1. Mark the Issue needs-info\n'
  # Take ready-for-agent off only when it is there (removing an absent label can fail).
  label_args=(--add-label needs-info)
  json_get "$issue" '.labels[]?.name' | grep -qxF ready-for-agent && label_args+=(--remove-label ready-for-agent)
  mutate gh issue edit "$number" -R "$repo" "${label_args[@]}" ||
    die "the label change failed; nothing else was done"
  printf '\n# 2. Release the claim\n'
  mutate gh issue edit "$number" -R "$repo" --remove-assignee @me ||
    die "the unassign failed after the label change; no comment was posted"
  printf '\n# 3. Post the failed report\n'
else
  printf '# Post the outcome (labels and assignee stay as they are)\n'
fi
mutate gh issue comment "$number" -R "$repo" --body-file - <<< "$body" || die "gh issue comment failed"
printf '\n%s\n' "$body"
[ "$APPLY" -eq 1 ] && printf '\nPosted: %s\n' "$MUTATE_OUT"
release_cmd
exit 0
