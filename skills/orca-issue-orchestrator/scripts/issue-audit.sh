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
    -h | --help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

hub_load "$hub_arg"

found=0
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  issues="$(gh_in_flight "$repo")" || die "cannot list the in-flight Issues of $repo"
  while IFS= read -r issue; do
    [ -n "$issue" ] || continue
    number="$(json_get "$issue" '.number')"
    prs="$(gh pr list -R "$repo" --state merged --search "$number in:body" --limit 50 \
      --json number,url,state,body)" || die "cannot list the PRs of $repo"
    merged="$(printf '%s' "$prs" | jq -r --arg n "$number" '
      .[] | select(.state == "MERGED")
      | select((.body // "") | test("(?i)\\b(close[sd]?|fix(e[sd])?|resolve[sd]?):?\\s+#" + $n + "\\b"))
      | .number')" || die "cannot read the PRs of $repo"
    for pr in $merged; do
      found=1
      notice="PR #$pr merged, Issue #$number still open: close it by hand"
      printf '%s: %s\n' "$repo" "$notice"
      if has_marker_comment "$issue" "$AUDIT_MARKER" "\"pr\":$pr}"; then
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

[ "$found" -eq 1 ] || printf 'No merged PR with an open in-flight Issue.\n'
[ "$APPLY" -eq 1 ] || [ "$found" -eq 0 ] || printf '\nDry-run; add --apply to post each notice on its Issue. This script never closes an Issue.\n'
exit 0
