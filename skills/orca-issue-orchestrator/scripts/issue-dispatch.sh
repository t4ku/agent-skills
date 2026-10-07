#!/usr/bin/env bash
# Dispatch one GitHub Issue to an Orca Worker, in two steps.
#
# Step 1 - claim and create the Task:
#   issue-dispatch.sh <owner/repo> <n> [--apply] [--force] [--hub <hub-dir>]
#   Checks the Issue (open, unassigned), the concurrency limit, and the bound
#   Run; then claims the Issue (assign @me) and creates the Task with the Spec.
#   It prints, and never runs, the placement: in a Hub folder that is a git worktree, one worker-start
#   --worktree new-top-level plus worktree set; in a folder-workspace Hub
#   (hub.json orca_worktree_id folder:<uuid>) worktree create --issue under the
#   Hub folder, then worker-start --worktree identity:<key>.
#
# Step 2 - after you ran worker-start, post the Mapping comment:
#   issue-dispatch.sh <owner/repo> <n> --receipt <file|-> [--apply] [--hub <hub-dir>]
#   Reads the worker-start JSON receipt. On success it posts the Mapping
#   comment, and prints worktree set when the worktree is not yet linked to the
#   Issue. When worker-start failed at agent_readiness with a live terminal, it
#   prints the retry command; on not_a_repo, the folder placement. A worktree
#   create receipt gets the worker-start to run on that worktree.
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

hub_arg="${CLAUDE_PROJECT_DIR:-$PWD}"
force=0
receipt=""
positional=()

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --force) force=1; shift ;;
    --hub) [ $# -ge 2 ] || die "--hub needs a directory"; hub_arg="$2"; shift 2 ;;
    --receipt) [ $# -ge 2 ] || die "--receipt needs a file or -"; receipt="$2"; shift 2 ;;
    -h | --help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) positional+=("$1"); shift ;;
  esac
done

[ "${#positional[@]}" -eq 2 ] || die "usage: issue-dispatch.sh <owner/repo> <n> [--apply] [--force] [--receipt <file|->] [--hub <hub-dir>]"
repo="${positional[0]}"
number="${positional[1]}"
printf '%s' "$repo" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || die "repo must be <owner>/<repo>: $repo"
printf '%s' "$number" | grep -Eq '^[1-9][0-9]*$' || die "Issue number must be a positive integer: $number"

hub_load "$hub_arg"
# Only the authenticated orchestrator's marker comments are trusted.
gh_login_load
repo_cfg="$(hub_repo "$repo")"
[ -n "$repo_cfg" ] || die "$repo is not in $HUB_JSON repos[]; add it there first"

if [ "$APPLY" -eq 1 ]; then mode="apply"; else mode="dry-run; add --apply to act"; fi

issue="$(gh_issue_view "$repo" "$number" number,title,body,state,assignees,url)" ||
  die "cannot read $repo#$number and all its comments"
title="$(json_get "$issue" '.title')"
name="$(worktree_name "$number" "$title")"

# base_branch: hub.json per-repo value, else the repo's default branch.
base="$(json_get "$repo_cfg" '.base_branch')"
if [ -z "$base" ]; then
  base="$(gh_default_branch "$repo")"
  [ -n "$base" ] || die "cannot read the default branch of $repo"
fi

# The Hub folder's Orca id when it is a folder workspace. worker-start
# --worktree new-top-level refuses such a Hub folder with not_a_repo, so the Worker's
# worktree is created under it first and worker-start reuses it.
hub_folder="$(hub_folder_id)"

# print_folder_placement <task-id> <identity-key>: worktree create under the
# Hub folder, linked to the Issue, then worker-start on the new worktree.
print_folder_placement() {
  print_cmd orca worktree create --repo "$repo_selector" --name "$name" --base-branch "$base" --issue "$number" \
    --setup skip --parent-worktree "${hub_folder:-folder:<hub_folder_id>}" --json
  print_worker_start_on "$1" "$2"
}

# print_worker_start_on <task-id> <identity-key>
print_worker_start_on() {
  print_cmd orca orchestration worker-start --task "$1" --worktree "identity:$2" --agent claude \
    --timeout-ms "$WORKER_TIMEOUT_MS" --json
}

# --- Step 2: the worker-start receipt -> Mapping comment ------------------------

# mapping_comment <run> <task> <dispatch> <worktree identity> <branch> <worktree name>
mapping_comment() {
  local block
  block="$(jq -cn --arg repo "$repo" --argjson issue "$number" --arg run "$1" --arg task "$2" \
    --arg dispatch "$3" --arg wt "$4" --arg branch "$5" --arg wt_name "$6" --arg hub "$(hub_id)" \
    '{v: 1, repo: $repo, issue: $issue, run_id: $run, task_id: $task, dispatch_id: $dispatch,
      worktree_id: $wt, worktree: $wt_name, branch: $branch, hub: $hub}')"
  printf '%s\n\n' "$DISCLAIMER"
  printf 'Dispatched to an Orca worker.\n'
  printf -- '- Worktree: `%s` (branch `%s`, base `%s`)\n' "$6" "$5" "$base"
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

  # A worktree create receipt (folder placement, first command): name the
  # worker-start that reuses the new worktree. identity is an object; take a
  # serialized one (JSON or the bare key) as well.
  created_key="$(json_get "$receipt_json" '.result.worktree.identity? |
    if type == "string" then (fromjson? // {key: .}) else . end | .key? | strings')"
  if [ -n "$created_key" ] && [ -z "$(r_first '.dispatchId?')" ]; then
    printf 'Worktree %s created. Start the Worker in it (run it yourself; this script never does):\n\n' \
      "$(json_get "$receipt_json" '.result.worktree.displayName // .result.worktree.id')"
    print_worker_start_on "<task_id>" "$created_key"
    printf '\nThen pipe the worker-start JSON into this script with --receipt - --apply.\n'
    exit 0
  fi

  # not_a_repo has been seen as {"ok":false,"error":"not_a_repo"}; take it as
  # an error code or a failed stage too.
  if printf '%s' "$receipt_json" | jq -e 'select(.ok == false) | [.. | objects | (.error?, .error?.code?, .failedStage?)
      | strings] | index("not_a_repo")' > /dev/null 2>&1; then
    repo_selector="$(orca_repo_selector "$repo")" ||
      die "no Orca repo has gitRemoteIdentity.canonicalKey github.com/$repo; add the repo to Orca first"
    printf 'worker-start refused the placement with not_a_repo: the Hub folder is a folder workspace, not a\n'
    printf 'git worktree. Do not retry it. Create the worktree under the Hub folder (linked to the Issue),\n'
    printf 'then start the Worker on its identity.key from that receipt (run them yourself):\n\n'
    print_folder_placement "$(r_first '(.taskId? // .task_id?)' | grep . || echo '<task_id>')" "<identity_key>"
    [ -n "$hub_folder" ] ||
      printf '\nhub.json has no folder:<uuid> orca_worktree_id; rerun init-hub, or take the id from orca worktree ps --json.\n'
    printf '\nNo Mapping comment was posted.\n'
    exit 3
  fi

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

  worktree="$(orca_worktree "$worktree_id")" || die "cannot read orca worktree list; no Mapping comment was posted"
  [ -n "$worktree" ] || die "worktree $worktree_id is not in orca worktree list"
  # A reused worktree (folder placement) may be named by its identity key.
  worktree_id="$(json_get "$worktree" '.id')"
  # Public comments carry the worktree identity key, never <repo-id>::<path>.
  worktree_key="$(json_get "$worktree" '.identity.key')"
  branch="$(json_get "$worktree" '.branch | sub("^refs/heads/"; "")')"
  [ -n "$worktree_key" ] && [ -n "$branch" ] || die "worktree $worktree_id has no identity key or branch"
  # The name the worktree was created with, kept in the block so closeout
  # never recomputes it from a title that may change: worker-start's
  # startOptions.name, else (a reused worktree) its Orca display name. Orca
  # derives the branch from that name, so the branch stands in last.
  wt_name="$(r_first '.startOptions?.name?')"
  [ -n "$wt_name" ] || wt_name="$(json_get "$worktree" '.displayName | strings')"
  [ -n "$wt_name" ] || wt_name="$branch"

  body="$(mapping_comment "$run_id" "$task_id" "$dispatch_id" "$worktree_key" "$branch" "$wt_name")"
  if frag="$(local_path_fragment "$body")"; then
    die "refusing to post: the Mapping comment would contain the local path $frag"
  fi

  printf 'Mapping for %s#%s (%s):\n\n' "$repo" "$number" "$mode"
  # worktree create --issue (folder placement) has linked it already.
  if [ "$(json_get "$worktree" '.linkedIssue')" != "$number" ]; then
    printf '# Link the worktree to the Issue in Orca (run it yourself; this script never does)\n'
    print_cmd orca worktree set --worktree "id:$worktree_id" --issue "$number" --json
    printf '\n'
  fi
  printf '# Post the Mapping comment\n'

  if has_marker_comment "$issue" "$MAPPING_MARKER" dispatch_id "$dispatch_id"; then
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
case "$limit" in '' | *[!0-9]*) die "concurrency in hub.json must be a non-negative integer: $limit" ;; esac
in_flight="$(gh_in_flight_count)" || die "cannot count every in-flight Issue (the gh search failed or was truncated); nothing was done"
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
  if [ -n "$hub_folder" ]; then placement="under the Hub folder"; else placement="top-level"; fi
  printf '%s, worktree %s (a fresh %s worktree; Orca derives the branch from this name), base %s\n\n' \
    "$repo" "$name" "$placement" "$base"
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
printf '%s --spec <Spec> --json\n' "$(print_cmd orca orchestration task-create --task-title "$task_title")"
task_id="<task_id>"
if [ "$APPLY" -eq 1 ]; then
  created="$(orca orchestration task-create --task-title "$task_title" --spec "$spec" --json)" ||
    die "task-create failed after the claim; the Issue is assigned to you. Fix and rerun step 2 by hand, or unassign"
  task_id="$(json_get "$created" '.result.task.id // .result.id // .result.taskId')"
  [ -n "$task_id" ] || die "task-create returned no task id: $created"
  printf 'Created Task %s\n' "$task_id"
fi

if [ -n "$hub_folder" ]; then
  printf '\n# 3. Create the worktree under the Hub folder, linked to the Issue, then start the Worker in it\n'
  printf '#    with the identity.key from the worktree create receipt (run them yourself; this script never does)\n'
  print_folder_placement "$task_id" "<identity_key>"
else
  printf '\n# 3. Start the Worker (run it yourself; this script never does)\n'
  print_cmd orca orchestration worker-start --task "$task_id" --worktree new-top-level --repo "$repo_selector" \
    --name "$name" --base-branch "$base" --agent claude --setup skip --timeout-ms "$WORKER_TIMEOUT_MS" --json

  printf '\n# 4. Link the worktree to the Issue (worktree id from the receipt; run it yourself)\n'
  print_cmd orca worktree set --worktree "id:<worktree_id>" --issue "$number" --json
fi

printf '\n# 5. Post the Mapping comment (from the worker-start receipt)\n'
print_cmd gh issue comment "$number" -R "$repo" --body-file -
printf '   Pipe the worker-start JSON into:\n   '
print_cmd "$SCRIPT_DIR/$(basename "$0")" "$repo" "$number" --receipt - --apply
printf '\n%s\n' "$(mapping_comment "${run_id:-<run_id>}" "$task_id" "<dispatch_id>" "<worktree_id>" "<branch>" "$name")"

printf '\n--- Spec ---\n%s\n--- end of Spec ---\n' "$spec"
