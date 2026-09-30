#!/usr/bin/env bash
# Dispatch one GitHub Issue to an Orca Worker, in two steps.
#
# Step 1 - claim and create the Task:
#   issue-dispatch.sh <owner/repo> <n> [--apply] [--force] [--hub <hub-dir>]
#   Checks the Issue (open, unassigned), the concurrency limit, and the bound
#   Run; then claims the Issue (assign @me) and creates the Task with the Spec.
#   It prints, and never runs, the worker-start and worktree set commands.
#
# Step 2 - after you ran worker-start, post the Mapping comment:
#   issue-dispatch.sh <owner/repo> <n> --receipt <file|-> [--apply] [--hub <hub-dir>]
#   Reads the worker-start JSON receipt. On success it prints the worktree set
#   command and posts the Mapping comment. When worker-start failed at
#   agent_readiness with a live terminal, it prints the retry command instead.
#
# Without --apply nothing changes: every gh / orca command that would change
# state is printed, in order. Reads (gh issue view, orca repo list, ...) run.
#   --force  Dispatch beyond hub.json `concurrency`
#   --hub    Hub folder (default: $CLAUDE_PROJECT_DIR, else the current directory)
#
# Exit codes: 0 done (or planned), 1 refused / error, 3 worker-start failed.

# Backticks in single-quoted strings are Markdown for the Spec and comments.
# shellcheck disable=SC2016

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh disable=SC1091
. "$SCRIPT_DIR/lib.sh"

WORKER_TIMEOUT_MS=300000

hub_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
force=0
receipt=""
positional=()

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --force) force=1; shift ;;
    --hub) [ $# -ge 2 ] || die "--hub needs a directory"; hub_dir="$2"; shift 2 ;;
    --receipt) [ $# -ge 2 ] || die "--receipt needs a file or -"; receipt="$2"; shift 2 ;;
    -h | --help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) positional+=("$1"); shift ;;
  esac
done

[ "${#positional[@]}" -eq 2 ] || die "usage: issue-dispatch.sh <owner/repo> <n> [--apply] [--force] [--receipt <file|->] [--hub <hub-dir>]"
repo="${positional[0]}"
number="${positional[1]}"
printf '%s' "$repo" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || die "repo must be <owner>/<repo>: $repo"
printf '%s' "$number" | grep -Eq '^[1-9][0-9]*$' || die "Issue number must be a positive integer: $number"

hub_load "$hub_dir"
repo_cfg="$(hub_repo "$repo")"
[ -n "$repo_cfg" ] || die "$repo is not in $HUB_JSON repos[]; add it there first"

if [ "$APPLY" -eq 1 ]; then mode="apply"; else mode="dry-run; add --apply to act"; fi

issue="$(gh issue view "$number" -R "$repo" --json number,title,body,state,assignees,url,comments)" ||
  die "cannot read $repo#$number"
title="$(json_get "$issue" '.title')"
name="$(worktree_name "$number" "$title")"

# base_branch: hub.json per-repo value, else the repo's default branch.
base="$(json_get "$repo_cfg" '.base_branch')"
if [ -z "$base" ]; then
  base="$(gh_default_branch "$repo")"
  [ -n "$base" ] || die "cannot read the default branch of $repo"
fi

# --- Step 2: the worker-start receipt -> Mapping comment ------------------------

# mapping_comment <run> <task> <dispatch> <worktree identity> <branch>
mapping_comment() {
  local block
  block="$(jq -cn --arg repo "$repo" --argjson issue "$number" --arg run "$1" --arg task "$2" \
    --arg dispatch "$3" --arg wt "$4" --arg branch "$5" --arg hub "$(hub_id)" \
    '{v: 1, repo: $repo, issue: $issue, run_id: $run, task_id: $task, dispatch_id: $dispatch,
      worktree_id: $wt, branch: $branch, hub: $hub}')"
  printf '%s\n\n' "$DISCLAIMER"
  printf 'Dispatched to an Orca worker.\n'
  printf -- '- Worktree: `%s` (branch `%s`, base `%s`)\n' "$name" "$5" "$base"
  printf -- '- Run `%s` / Task `%s` / Dispatch `%s`\n\n' "$1" "$2" "$3"
  printf '<!-- %s %s -->\n' "$MAPPING_MARKER" "$block"
}

if [ -n "$receipt" ]; then
  if [ "$receipt" = "-" ]; then
    receipt_json="$(cat)"
  else
    [ -f "$receipt" ] || die "no receipt file: $receipt"
    receipt_json="$(cat "$receipt")"
  fi
  printf '%s' "$receipt_json" | jq -e . > /dev/null 2>&1 || die "the receipt is not JSON"

  r_first() { json_get "$receipt_json" "first(.. | objects | $1 | select(type == \"string\" and length > 0))"; }
  failed_stage="$(r_first '.failedStage?')"
  dispatch_id="$(r_first '.dispatchId?')"
  [ -n "$dispatch_id" ] || dispatch_id="$(json_get "$receipt_json" '.result.dispatch.id')"
  task_id="$(r_first '(.taskId? // .task_id?)')"
  run_id="$(r_first '(.runId? // .run_id?)')"
  worktree_id="$(r_first '(.worktreeId? // (select(.kind? == "worktree") | .id))')"

  if [ -n "$failed_stage" ]; then
    printf 'worker-start failed at stage %s (Dispatch %s).\n' "$failed_stage" "${dispatch_id:-unknown}"
    terminal="$(json_get "$receipt_json" \
      'first(.. | objects | .residualResources? // empty | .[] | select(.kind == "terminal" and (.role // "agent") == "agent") | .id)')"
    if [ "$failed_stage" = "agent_readiness" ] && [ -n "$terminal" ] && [ -n "$task_id" ] &&
      [ -n "$dispatch_id" ] && [ -n "$worktree_id" ]; then
      printf 'Its terminal %s is still live. Check it with worker-show; if the agent is up, retry on it:\n\n' "$terminal"
      print_cmd orca orchestration worker-start --task "$task_id" --retry-of "$dispatch_id" \
        --terminal "$terminal" --worktree "id:$worktree_id" --timeout-ms "$WORKER_TIMEOUT_MS" --json
      printf '\nThen run this script again with the new receipt. No Mapping comment was posted.\n'
    else
      printf 'Do not relaunch. Read the receipt'"'"'s residualResources and recovery commands, then follow\n'
      printf 'references/recovery-and-cleanup.md from `orca skills get orchestration --full`.\n'
      printf 'No Mapping comment was posted.\n'
    fi
    exit 3
  fi

  [ -n "$dispatch_id" ] && [ -n "$task_id" ] && [ -n "$run_id" ] && [ -n "$worktree_id" ] ||
    die "the receipt lacks dispatchId, taskId, runId, or the worktree id"

  worktree="$(orca_worktree "$worktree_id")"
  [ -n "$worktree" ] || die "worktree $worktree_id is not in orca worktree list"
  # Public comments carry the worktree identity key, never <repo-id>::<path>.
  worktree_key="$(json_get "$worktree" '.identity.key')"
  branch="$(json_get "$worktree" '.branch | sub("^refs/heads/"; "")')"
  [ -n "$worktree_key" ] && [ -n "$branch" ] || die "worktree $worktree_id has no identity key or branch"

  body="$(mapping_comment "$run_id" "$task_id" "$dispatch_id" "$worktree_key" "$branch")"
  case "$body" in
    *::/* | *"$hub_dir"* | *"${HOME:-/nonexistent-home}"*)
      die "refusing to post: the Mapping comment would contain a local path" ;;
  esac

  printf 'Mapping for %s#%s (%s):\n\n' "$repo" "$number" "$mode"
  printf '# Link the worktree to the Issue in Orca (run it yourself; this script never does)\n'
  print_cmd orca worktree set --worktree "id:$worktree_id" --issue "$number" --json
  printf '\n# Post the Mapping comment\n'

  if json_get "$issue" '.comments[]?.body' | grep -F "$MAPPING_MARKER" | grep -qF "\"dispatch_id\":\"$dispatch_id\""; then
    printf 'A Mapping comment for Dispatch %s is already on the Issue; not posting again.\n' "$dispatch_id"
    exit 0
  fi
  mutate gh issue comment "$number" -R "$repo" --body-file - <<< "$body" || die "gh issue comment failed"
  printf '\n%s\n' "$body"
  [ "$APPLY" -eq 1 ] && printf '\nPosted: %s\n' "$MUTATE_OUT"
  exit 0
fi

# --- Step 1: claim, Task, and the commands to start the Worker ------------------

state="$(json_get "$issue" '.state')"
[ "$state" = "OPEN" ] || die "$repo#$number is $state, not OPEN"
assignees="$(json_get "$issue" '[.assignees[]?.login] | join(", ") | select(length > 0)')"
[ -z "$assignees" ] || die "$repo#$number is already claimed by $assignees"

limit="$(hub_concurrency)"
in_flight="$(gh_in_flight_count)"
if [ "$in_flight" -ge "$limit" ]; then
  if [ "$force" -eq 1 ]; then
    note "warning: $in_flight Issue(s) in flight, concurrency $limit; dispatching anyway (--force)"
  else
    die "concurrency limit reached: $in_flight Issue(s) in flight, concurrency $limit in hub.json. Wait for one to settle, or pass --force"
  fi
fi

repo_selector="$(orca_repo_selector "$repo")" ||
  die "no Orca repo has gitRemoteIdentity.canonicalKey github.com/$repo; add the repo to Orca first"

run_id="$(orca_bound_run)"
if [ -z "$run_id" ]; then
  if [ "$APPLY" -eq 1 ]; then
    note "No Run is bound to this terminal. Create one per Orchestrator session first:"
    print_cmd orca orchestration run-create --objective "Issues of $(hub_id)" --json >&2
    exit 1
  fi
  note "note: no Run is bound; --apply will refuse until you run: orca orchestration run-create --objective <objective> --json"
fi

constraints="$(json_get "$repo_cfg" '.constraints[]? | "- " + .')"
spec="$(
  printf 'Issue: %s\n' "$(json_get "$issue" '.url')"
  printf 'Task: #%s %s\n\n' "$number" "$title"
  printf '## Target\n'
  printf '%s, worktree %s (a fresh top-level worktree; Orca derives the branch from this name), base %s\n\n' \
    "$repo" "$name" "$base"
  printf '## Change\n'
  printf '%s\n\n' "$(json_get "$issue" '.body')"
  printf '## Constraints\n'
  printf -- '- Do not touch the Issue (labels, assignee, comments, close). The only GitHub write you make is `gh pr create`.\n'
  printf -- '- Stay inside this worktree. Do not edit other worktrees or the Hub folder.\n'
  [ -z "$constraints" ] || printf '%s\n' "$constraints"
  printf '\n## How to work\n'
  printf -- '- Follow `/implement`: `/tdd` at agreed seams, typecheck often, full test suite once at the end, `/code-review`, then commit to the current branch.\n'
  printf -- '- Open a PR: `gh pr create --title "#%s %s" --body-file <file>` with `Closes #%s` as the first line of the body.\n' \
    "$number" "$title" "$number"
  printf '\n## Done\n'
  printf -- '- Send `worker_done` exactly once from this terminal: `--outcome succeeded` only if the PR is open, otherwise `--outcome failed`. Three-sentence summary, include the PR URL, `--files-modified` with real values.\n'
  printf -- '- If you are blocked, use the `ask` command from the preamble; never open a local question prompt.\n'
)"

task_title="#$number $title"

printf 'Dispatch plan for %s#%s (%s):\n\n' "$repo" "$number" "$mode"

printf '# 1. Claim the Issue\n'
mutate gh issue edit "$number" -R "$repo" --add-assignee @me || die "claim failed; nothing else was done"

printf '\n# 2. Create the Task (Spec below)\n'
printf '%s --spec <Spec>\n' "$(print_cmd orca orchestration task-create --task-title "$task_title")"
task_id="<task_id>"
if [ "$APPLY" -eq 1 ]; then
  created="$(orca orchestration task-create --task-title "$task_title" --spec "$spec" --json)" ||
    die "task-create failed after the claim; the Issue is assigned to you. Fix and rerun step 2 by hand, or unassign"
  task_id="$(json_get "$created" '.result.task.id // .result.id // .result.taskId')"
  [ -n "$task_id" ] || die "task-create returned no task id: $created"
  printf 'Created Task %s\n' "$task_id"
fi

printf '\n# 3. Start the Worker (run it yourself; this script never does)\n'
print_cmd orca orchestration worker-start --task "$task_id" --worktree new-top-level --repo "$repo_selector" \
  --name "$name" --base-branch "$base" --agent claude --setup skip --timeout-ms "$WORKER_TIMEOUT_MS" --json

printf '\n# 4. Link the worktree to the Issue (worktree id from the receipt; run it yourself)\n'
print_cmd orca worktree set --worktree "id:<worktree_id>" --issue "$number" --json

printf '\n# 5. Post the Mapping comment (from the receipt of step 3)\n'
print_cmd gh issue comment "$number" -R "$repo" --body-file -
printf '   Pipe the worker-start JSON into:\n   '
print_cmd "$SCRIPT_DIR/$(basename "$0")" "$repo" "$number" --receipt - --apply
printf '\n%s\n' "$(mapping_comment "${run_id:-<run_id>}" "$task_id" "<dispatch_id>" "<worktree_id>" "<branch>")"

printf '\n--- Spec ---\n%s\n--- end of Spec ---\n' "$spec"
