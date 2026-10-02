#!/usr/bin/env bash
# Find in-flight Issues whose PR is merged but which are still open.
#
# GitHub does not always link `Closes #123` from a PR body
# (closingIssuesReferences can stay empty), so a merge may leave the Issue
# open. For every repo in .orca-hub/hub.json and every open Issue assigned to
# @me that carries a Mapping block, this looks up the PRs whose body says
# "Closes / Fixes / Resolves #<n>" and, for each merged one, prints:
#
#   <owner>/<repo>: PR #<p> merged, Issue #<n> still open: close it by hand
#
# Every page of the PR search is read; when GitHub cannot return all of it
# (more than 1000 matches, or an incomplete search) the script fails rather
# than report no leftover Issue (it still checks the other Issues, then exits 1).
#
# Usage: issue-audit.sh [--apply] [--hub <hub-dir>]
#   --apply  Also post that notice as a comment on the Issue (once per PR)
#   --hub    Hub folder (default: $CLAUDE_PROJECT_DIR, else the current directory)
#
# It never closes an Issue. Exit codes: 0 done (or planned), 1 error.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh disable=SC1091
. "$SCRIPT_DIR/lib.sh"

hub_arg="${CLAUDE_PROJECT_DIR:-$PWD}"

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --hub) [ $# -ge 2 ] || die "--hub needs a directory"; hub_arg="$2"; shift 2 ;;
    -h | --help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

hub_load "$hub_arg"
# Only the authenticated orchestrator's marker comments are trusted.
gh_login_load

found=0
# Set when an Issue could not be checked; the others still are, then exit 1.
failed=0
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  issues="$(gh_in_flight "$repo")" || die "cannot list the in-flight Issues of $repo"
  while IFS= read -r issue; do
    [ -n "$issue" ] || continue
    number="$(json_get "$issue" '.number')"
    # Every page before the exact filter: the broad numeric search can match
    # many PRs, and a cap could hide the merged one that closes the Issue.
    prs="$(gh api --paginate -X GET search/issues -f q="repo:$repo is:pr is:merged $number in:body" \
      -f per_page=100)" || {
      note "error: cannot search the PRs of $repo naming $number; not reporting on #$number"
      failed=1
      continue
    }
    # {merged: [PR numbers]} from every page, or {error}.
    merged="$(printf '%s' "$prs" | jq -cs --arg n "$number" '
      if length > 0 and all(.[]; (.items? | type) == "array" and (.total_count | type) == "number") then
        [.[].items[]] as $items
        | if any(.[]; .incomplete_results == true) then {error: "GitHub returned an incomplete search"}
          elif (map(.total_count) | max) > ($items | length) then
            {error: "the search returned \($items | length) of \(map(.total_count) | max) PRs (GitHub search stops at 1000)"}
          else {merged: [$items[]
            | select(.pull_request.merged_at? != null)
            | select((.body // "") | test("(?i)\\b(close[sd]?|fix(e[sd])?|resolve[sd]?):?\\s+#" + $n + "\\b"))
            | .number]} end
      else {error: "gh answered with something that is not search pages"} end' 2> /dev/null)" || merged=""
    if [ -z "$merged" ] || [ -n "$(json_get "$merged" '.error')" ]; then
      note "error: cannot read every PR of $repo naming $number ($(json_get "$merged" '.error' 2> /dev/null || true)); not reporting on #$number"
      failed=1
      continue
    fi
    merged="$(json_get "$merged" '.merged[]')"
    for pr in $merged; do
      found=1
      notice="PR #$pr merged, Issue #$number still open: close it by hand"
      printf '%s: %s\n' "$repo" "$notice"
      if has_marker_comment "$issue" "$AUDIT_MARKER" pr "$pr"; then
        printf '  (the notice is already on the Issue)\n'
        continue
      fi
      body="$(printf '%s\n\n%s.\n\n<!-- %s %s -->\n' "$DISCLAIMER" "$notice" "$AUDIT_MARKER" \
        "$(jq -cn --argjson pr "$pr" '{v: 1, pr: $pr}')")"
      mutate gh issue comment "$number" -R "$repo" --body-file - <<< "$body" || die "gh issue comment failed"
    done
  done <<EOF_ISSUES
$(printf '%s' "$issues" | jq -c '.[]')
EOF_ISSUES
done <<EOF_REPOS
$(hub_repos)
EOF_REPOS

[ "$found" -eq 1 ] || [ "$failed" -eq 1 ] || printf 'No merged PR with an open in-flight Issue.\n'
[ "$APPLY" -eq 1 ] || [ "$found" -eq 0 ] || printf '\nDry-run; add --apply to post each notice on its Issue. This script never closes an Issue.\n'
[ "$failed" -eq 0 ] || die "some Issues could not be checked (see above); the audit is incomplete"
exit 0
