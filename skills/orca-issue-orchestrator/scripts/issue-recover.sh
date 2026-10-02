#!/usr/bin/env bash
# Recover in-flight Issues after an Orca restart.
#
# For every repo in .orca-hub/hub.json it lists the open Issues assigned to
# @me that carry a Mapping block, reads the latest block on each (Run, Task,
# Dispatch, worktree, branch), and reconciles it with Orca:
#   orca orchestration worker-list --run <run_id> --json   the fleet view
#   orca worktree list --json                              identity.key, linkedIssue
# Then it prints the `run-use` that re-binds this terminal to the Run.
#
# Usage: issue-recover.sh [--apply] [--json] [--hub <hub-dir>]
#   --apply  Run the run-use (the only thing it ever changes). Refuses when the
#            Issues name more than one Run; bind the one you want by hand.
#   --json   Print {issues: [...], runs: [...], bound_run, run_use} instead of text
#   --hub    Hub folder (default: $CLAUDE_PROJECT_DIR, else the current directory)
#
# State per Issue: closed-out (a closeout comment for the Dispatch is posted;
# wait for the merge, check with issue-audit.sh), succeeded / failed
# (worker_done arrived; close it out),
# working (live agent, no outcome yet), inspect (no outcome, agent not proven
# live), unknown (worker-list answered with no row for the Dispatch). A
# failing worker-list stops it with exit 1: nothing is reported or bound.
# Exit codes: 0 done (or planned), 1 refused / error.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh disable=SC1091
. "$SCRIPT_DIR/lib.sh"

hub_arg="${CLAUDE_PROJECT_DIR:-$PWD}"
as_json=0

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --json) as_json=1; shift ;;
    --hub) [ $# -ge 2 ] || die "--hub needs a directory"; hub_arg="$2"; shift 2 ;;
    -h | --help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

hub_load "$hub_arg"
# Only the authenticated orchestrator's marker comments are trusted.
gh_login_load

# --- 1. The Issues and their latest Mapping block ----------------------------------

rows='[]'
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  issues="$(gh_in_flight "$repo")" || die "cannot list the in-flight Issues of $repo; nothing was done"
  while IFS= read -r issue; do
    [ -n "$issue" ] || continue
    # gh_in_flight already warned about every ignored block.
    block="$(MAPPING_QUIET=1 mapping_latest "$issue" "$repo")" || die "cannot read the Mapping blocks on $repo; nothing was done"
    [ -n "$block" ] || continue
    closed_out=false
    has_marker_comment "$issue" "$CLOSEOUT_MARKER" dispatch_id "$(json_get "$block" '.dispatch_id')" &&
      closed_out=true
    rows="$(jq -cn --argjson rows "$rows" --arg repo "$repo" --argjson i "$issue" --argjson b "$block" \
      --argjson closed "$closed_out" '
      $rows + [{repo: $repo, issue: $i.number, title: $i.title, url: $i.url, closed_out: $closed,
        run_id: $b.run_id, task_id: $b.task_id, dispatch_id: $b.dispatch_id,
        worktree_id: $b.worktree_id, branch: $b.branch}]')"
  done <<EOF_ISSUES
$(printf '%s' "$issues" | jq -c '.[]')
EOF_ISSUES
done <<EOF_REPOS
$(hub_repos)
EOF_REPOS

if [ "$(printf '%s' "$rows" | jq 'length')" -eq 0 ]; then
  if [ "$as_json" -eq 1 ]; then
    jq -n '{issues: [], runs: [], bound_run: null, run_use: null}'
  else
    printf 'No in-flight Issues: none open, assigned to you, with a Mapping comment.\n'
  fi
  exit 0
fi

# --- 2. Reconcile with Orca ----------------------------------------------------------

runs="$(printf '%s' "$rows" | jq -c '[.[].run_id | select(type == "string" and length > 0)] | unique')"
workers='[]'
while IFS= read -r run; do
  [ -n "$run" ] || continue
  # "unknown" means Orca answered with no row for the Dispatch; an outage
  # must not pass for that.
  run_workers="$(orca_workers "$run")" || die "orca orchestration worker-list --run $run failed; nothing was done"
  workers="$(jq -cn --argjson a "$workers" --argjson b "$run_workers" '$a + $b')"
done <<EOF_RUNS
$(printf '%s' "$runs" | jq -r '.[]')
EOF_RUNS
wt_list="$(orca worktree list --json)" || die "orca worktree list failed; nothing was done"
worktrees="$(printf '%s' "$wt_list" | jq -c '.result.worktrees // []')" && [ -n "$worktrees" ] ||
  die "orca worktree list returned no JSON; nothing was done"

closeout="$SCRIPT_DIR/issue-closeout.sh"
audit="$SCRIPT_DIR/issue-audit.sh"
rows="$(jq -cn --argjson rows "$rows" --argjson workers "$workers" --argjson wts "$worktrees" \
  --arg closeout "$closeout" --arg audit "$audit" '
  $rows | map(
    . as $r
    | (first($workers[] | select(.dispatchId == $r.dispatch_id)) // null) as $w
    | (first($workers[] | select(.taskId == $r.task_id) | .dispatchId) // null) as $newest
    | (first($wts[] | select(.identity.key? == $r.worktree_id)) // null) as $wt
    | (if $r.closed_out then "closed-out"
       elif $w == null then "unknown"
       elif $w.projection.outcome == "succeeded" then "succeeded"
       elif $w.projection.outcome == "failed" then "failed"
       elif $w.projection.liveness.verdict == "live" then "working"
       else "inspect" end) as $state
    | . + {
        worker: (if $w == null then null else {
          workerState: $w.workerState, outcome: $w.projection.outcome,
          liveness: $w.projection.liveness.verdict, terminalState: $w.terminalState,
          ownership: $w.resource.ownershipState, retainedReason: $w.resource.retainedReason} end),
        newer_dispatch: (if $newest != null and $newest != $r.dispatch_id then $newest else null end),
        worktree: (if $wt == null then "missing" elif $wt.linkedIssue == $r.issue then "linked" else "unlinked" end),
        link: (if $wt != null and $wt.linkedIssue != $r.issue then
          ["orca", "worktree", "set", "--worktree", "identity:" + $r.worktree_id, "--issue", ($r.issue | tostring), "--json"]
          else null end),
        state: $state,
        next: (if $state == "closed-out" then [$audit]
          elif $state == "succeeded" then [$closeout, $r.repo, ($r.issue | tostring), "succeeded", "<summary_file>"]
          elif $state == "failed" then [$closeout, $r.repo, ($r.issue | tostring), "failed", "<summary_file>", "--needs", "<text>"]
          elif $state == "working" then ["orca", "orchestration", "check", "--wait", "--types", "worker_done,escalation,question", "--json"]
          else ["orca", "orchestration", "worker-show", "--dispatch", $r.dispatch_id, "--json"] end)
      })')"

bound="$(orca_bound_run)"
run_count="$(printf '%s' "$runs" | jq 'length')"
run_use='null'
[ "$run_count" -ne 1 ] ||
  run_use="$(printf '%s' "$runs" | jq -c '["orca", "orchestration", "run-use", "--id", .[0], "--json"]')"

# --- 3. Report ------------------------------------------------------------------------

if [ "$as_json" -eq 1 ]; then
  jq -n --argjson issues "$rows" --argjson runs "$runs" --arg bound "$bound" --argjson run_use "$run_use" \
    '{issues: $issues, runs: $runs, bound_run: (if $bound == "" then null else $bound end), run_use: $run_use}'
else
  if [ "$APPLY" -eq 1 ]; then mode="apply"; else mode="dry-run; add --apply to run run-use"; fi
  printf 'In-flight Issues (%s):\n' "$mode"
  while IFS= read -r row; do
    printf '\n%s#%s  %s\n' "$(json_get "$row" '.repo')" "$(json_get "$row" '.issue')" "$(json_get "$row" '.title')"
    printf '  Issue     %s\n' "$(json_get "$row" '.url')"
    printf '  Run       %s\n' "$(json_get "$row" '.run_id')"
    printf '  Task      %s\n' "$(json_get "$row" '.task_id')"
    printf '  Dispatch  %s\n' "$(json_get "$row" '.dispatch_id')"
    printf '  Worktree  %s\n' "$(json_get "$row" '"\(.worktree_id) (branch \(.branch)): " +
      ({linked: "linked to the Issue", unlinked: "not linked to the Issue in Orca",
        missing: "not in orca worktree list"}[.worktree])')"
    printf '  Worker    %s\n' "$(json_get "$row" 'if .worker == null then "no worker row for this Dispatch in the Run" else
      .worker | "\(.outcome); liveness \(.liveness); terminal \(.terminalState)" +
        (if .retainedReason then " (\(.retainedReason))" else "" end) end')"
    newer="$(json_get "$row" '.newer_dispatch')"
    [ -z "$newer" ] || printf '  Note      the Task has a newer Dispatch %s with no Mapping comment\n' "$newer"
    printf '  State     %s\n' "$(json_get "$row" '.state')"
    printf '  Next      %s\n' "$(print_cmd_json "$(json_get "$row" '.next' -c)")"
    link="$(json_get "$row" '.link' -c)"
    [ -z "$link" ] || printf '  Link      %s\n' "$(print_cmd_json "$link")"
  done <<EOF_ROWS
$(printf '%s' "$rows" | jq -c '.[]')
EOF_ROWS
  printf '\n# Re-bind the Run\n'
fi

# Commands go to stderr under --json so stdout stays one JSON document.
say() { if [ "$as_json" -eq 1 ]; then printf '%s\n' "$*" >&2; else printf '%s\n' "$*"; fi; }

if [ "$run_count" -gt 1 ]; then
  say "The Issues name $run_count Runs; a terminal binds one. Run the one you want:"
  while IFS= read -r run; do
    say "$(print_cmd orca orchestration run-use --id "$run" --json)"
  done <<EOF_RUNS
$(printf '%s' "$runs" | jq -r '.[]')
EOF_RUNS
  [ "$APPLY" -eq 0 ] || die "several Runs; bind one by hand. Nothing was changed"
  exit 0
fi

run="$(printf '%s' "$runs" | jq -r '.[0] // empty')"
[ -n "$run" ] || die "the Mapping blocks carry no run_id"
if [ "$run" = "$bound" ]; then
  say "$(print_cmd orca orchestration run-use --id "$run" --json)"
  say "This terminal is already bound to $run; not running it."
  exit 0
fi
if [ "$as_json" -eq 1 ]; then
  mutate orca orchestration run-use --id "$run" --json >&2 || die "run-use failed"
else
  mutate orca orchestration run-use --id "$run" --json || die "run-use failed"
fi
exit 0
