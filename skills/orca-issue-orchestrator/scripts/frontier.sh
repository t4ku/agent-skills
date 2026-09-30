#!/usr/bin/env bash
# List the Frontier: open `ready-for-agent` Issues with no open blocker
# (issue_dependencies_summary.blocked_by == 0) and no assignee, across every
# repo in .orca-hub/hub.json. Read-only; it never changes an Issue.
#
# Usage: frontier.sh [--hub <hub-dir>] [--json]
#   --hub   Hub folder (default: $CLAUDE_PROJECT_DIR, else the current directory)
#   --json  Print a JSON array of {repo, number, title, url} instead of
#           tab-separated "<owner>/<repo>#<n>  <title>  <url>" lines
#
# Order: repos as listed in hub.json, then Issue number ascending.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh disable=SC1091
. "$SCRIPT_DIR/lib.sh"

hub_arg="${CLAUDE_PROJECT_DIR:-$PWD}"
as_json=0

while [ $# -gt 0 ]; do
  case "$1" in
    --hub) [ $# -ge 2 ] || die "--hub needs a directory"; hub_arg="$2"; shift 2 ;;
    --json) as_json=1; shift ;;
    -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

hub_load "$hub_arg"

all='[]'
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  issues="$(gh api --paginate "repos/$repo/issues?labels=ready-for-agent&state=open&per_page=100")" ||
    die "gh api failed for $repo"
  all="$(jq -c -n --argjson acc "$all" --arg repo "$repo" --slurpfile pages <(printf '%s' "$issues") '
    $acc + ([$pages[] | if type == "array" then .[] else . end]
      | map(select(.pull_request == null
          and ((.assignees // []) | length) == 0
          and (.issue_dependencies_summary.blocked_by // 0) == 0))
      | map({repo: $repo, number, title, url: .html_url})
      | sort_by(.number))')"
done <<EOF_REPOS
$(hub_repos)
EOF_REPOS

if [ "$as_json" -eq 1 ]; then
  printf '%s\n' "$all" | jq .
else
  printf '%s\n' "$all" | jq -r '.[] | "\(.repo)#\(.number)\t\(.title)\t\(.url)"'
fi
