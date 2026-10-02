#!/usr/bin/env bash
# Executable-boundary tests for scripts/frontier.sh and scripts/issue-dispatch.sh.
#
# Puts fake `gh` and `orca` (tests/bin/) first on PATH. They answer from the
# recorded JSON in tests/fixtures/ and append every argv to a log, one JSON
# array per line. The tests assert on stdout, the exit code, and that log.
# Dependencies: bash, jq, coreutils.
#
# Usage: tests/dispatch.test.sh

# The bash -c snippets expand their variables in the child shell.
# shellcheck disable=SC2016

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh disable=SC1091
. "$SCRIPT_DIR/helpers.sh"
FRONTIER="$SCRIPTS/frontier.sh"
DISPATCH="$SCRIPTS/issue-dispatch.sh"

# --- frontier.sh --------------------------------------------------------------

reset_fakes
run "$FRONTIER" --hub "$HUB"
check "frontier: exits 0" code_is 0
check "frontier: lists the unblocked, unassigned app Issue" \
  out_has_line "$(printf 'example/app#7\tAdd login page\thttps://github.com/example/app/issues/7')"
check "frontier: lists Issues from every configured repo" \
  out_has_line "$(printf 'example/api#3\tRate limit the export endpoint\thttps://github.com/example/api/issues/3')"
check "frontier: excludes a blocked Issue" out_lacks "example/app#8"
check "frontier: excludes an assigned Issue" out_lacks "example/app#9"
check "frontier: excludes pull requests" out_lacks "example/app#11"
check "frontier: queries ready-for-agent open Issues" \
  bash -c 'jq -r "select(.[0]==\"gh\" and .[1]==\"api\") | .[]" "$FAKE_LOG" | grep "^repos/" | grep -q "labels=ready-for-agent.*state=open\|state=open.*labels=ready-for-agent"'
check "frontier: makes no mutation" no_mutation

reset_fakes
run "$FRONTIER" --hub "$HUB" --json
check "frontier --json: an array of the two frontier Issues" \
  bash -c 'printf "%s" "$1" | jq -e "map(\"\(.repo)#\(.number)\") == [\"example/app#7\", \"example/api#3\"]" >/dev/null' _ "$OUT"

# --- issue-dispatch.sh: dry-run -------------------------------------------------

CLAIM='gh issue edit 7 -R example/app --add-assignee @me'
WORKER_START_DRY='orca orchestration worker-start --task <task_id> --worktree new-top-level --repo id:repo-app-id --name issue-7-add-login-page --base-branch main --agent claude --setup skip --timeout-ms 300000 --json'
WORKTREE_SET_DRY='orca worktree set --worktree id:<worktree_id> --issue 7 --json'
COMMENT='gh issue comment 7 -R example/app --body-file -'

reset_fakes
run "$DISPATCH" example/app 7 --hub "$HUB"
check "dry-run: exits 0" code_is 0
check "dry-run: prints the claim" out_has_line "$CLAIM"
check "dry-run: prints the task-create" out_has "orca orchestration task-create --task-title '#7 Add login page' --spec "
check "dry-run: prints the worker-start" out_has_line "$WORKER_START_DRY"
check "dry-run: prints the worktree set" out_has_line "$WORKTREE_SET_DRY"
check "dry-run: prints the comment" out_has_line "$COMMENT"
in_order() {
  local a b c d e
  a="$(line_no "$CLAIM")"; b="$(printf '%s\n' "$OUT" | grep -n '^orca orchestration task-create ' | head -1 | cut -d: -f1)"
  c="$(line_no "$WORKER_START_DRY")"; d="$(line_no "$WORKTREE_SET_DRY")"; e="$(line_no "$COMMENT")"
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] && [ -n "$e" ] &&
    [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$d" ] && [ "$d" -lt "$e" ]
}
check "dry-run: claim, task-create, worker-start, worktree set, comment in that order" in_order
check "dry-run: the shims log no mutation" no_mutation
check "dry-run: the Spec carries the Issue body verbatim" \
  out_has "Keep \$HOME and 'quotes' and \\backslashes\\ exactly as written."
check "dry-run: the Spec names the Issue URL" out_has_line "Issue: https://github.com/example/app/issues/7"
check "dry-run: the Spec has the Task title" out_has_line "Task: #7 Add login page"
check "dry-run: the Spec forbids Issue writes" \
  out_has "Do not touch the Issue (labels, assignee, comments, close). The only GitHub write you make is \`gh pr create\`."
check "dry-run: the Spec asks for /implement" out_has "Follow \`/implement\`"
check "dry-run: the Spec asks for Closes #7 first in the PR body" out_has "\`Closes #7\` as the first line"
check "dry-run: the Spec has the worker_done rules" out_has "Send \`worker_done\` exactly once"
check "dry-run: the comment starts with the AI disclaimer" out_has_line "> *Posted by an AI orchestrator.*"

reset_fakes
run "$DISPATCH" example/api 3 --hub "$HUB"
check "dry-run: per-repo base_branch goes into worker-start" \
  out_has_line 'orca orchestration worker-start --task <task_id> --worktree new-top-level --repo id:repo-api-id --name issue-3-rate-limit-the --base-branch develop --agent claude --setup skip --timeout-ms 300000 --json'
check "dry-run: per-repo constraints go into the Spec" out_has_line "- Run the full test suite before opening the PR."
check "dry-run: the base branch is named in the Spec" out_has "base develop"

# --- issue-dispatch.sh: --apply -------------------------------------------------

reset_fakes
run "$DISPATCH" example/app 7 --hub "$HUB" --apply
check "apply: exits 0" code_is 0
check "apply: claims the Issue" called "gh issue edit 7"
check "apply: creates the Task" called "orca orchestration task-create"
claim_first() {
  local a b
  a="$(call_line "gh issue edit 7")"; b="$(call_line "orca orchestration task-create")"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
check "apply: the claim comes before task-create" claim_first
check "apply: the claim assigns @me" \
  bash -c 'jq -e "select(.[1]==\"issue\" and .[2]==\"edit\") | index(\"--add-assignee\") as \$i | .[\$i+1] == \"@me\"" "$FAKE_LOG" >/dev/null'
check "apply: task-create gets the Task title" \
  bash -c 'jq -e "select(.[2]==\"task-create\") | index(\"--task-title\") as \$i | .[\$i+1] == \"#7 Add login page\"" "$FAKE_LOG" >/dev/null'
check "apply: task-create gets the Issue body verbatim in the Spec" \
  bash -c 'jq -e --arg b "$(jq -r .body "$1")" "select(.[2]==\"task-create\") | index(\"--spec\") as \$i | .[\$i+1] | contains(\$b)" "$FAKE_LOG" >/dev/null' _ "$FIXTURES/issue-example_app-7.json"
check "apply: worker-start is never invoked" not_called "orca orchestration worker-start"
check "apply: worktree set is never invoked" not_called "orca worktree set"
check "apply: task-update is never invoked" not_called "orca orchestration task-update"
check "apply: no comment before the Worker exists" not_called "gh issue comment"
check "apply: prints the worker-start for the created Task" \
  out_has_line 'orca orchestration worker-start --task task_test1 --worktree new-top-level --repo id:repo-app-id --name issue-7-add-login-page --base-branch main --agent claude --setup skip --timeout-ms 300000 --json'
check "apply: prints the next step that takes the receipt" out_has "--receipt - --apply"

# --- issue-dispatch.sh: refusals ------------------------------------------------

# One open Issue assigned to @me with a Mapping block.
# in_flight_api <author> <jq update of the block>: example/api#5 in flight,
# its one Mapping block posted by <author>, then updated.
in_flight_api() {
  jq -cn --arg a "$1" --argjson b "$(jq -cn '{v: 1, repo: "example/api", issue: 5, run_id: "run_test1", task_id: "task_5",
      dispatch_id: "ctx_5", worktree_id: "wt2:local:inst-5", branch: "issue-5", hub: "example-hub"}' | jq -c "$2")" \
    '[{number: 5, comments: [{author: {login: $a}, body: ("<!-- orca-issue-orchestrator " + ($b | tojson) + " -->")}]}]'
}
IN_FLIGHT_ONE="$(in_flight_api orchestrator .)"

reset_fakes
printf '%s\n' "$IN_FLIGHT_ONE" > "$OVR/inflight-example_api.json"
run "$DISPATCH" example/app 7 --hub "$HUB" --apply
check "concurrency: refuses beyond the limit" code_is 1
check "concurrency: says why" out_has "concurrency"
check "concurrency: nothing is claimed" no_mutation
check "concurrency: counts open Issues assigned to @me with the Mapping marker, every page" \
  bash -c 'jq -e "select(.[1]==\"api\" and index(\"graphql\") and index(\"--paginate\")) | map(select(startswith(\"q=\")))[0] | contains(\"is:issue\") and contains(\"is:open\") and contains(\"assignee:@me\") and contains(\"orca-issue-orchestrator\")" "$FAKE_LOG" >/dev/null'

reset_fakes
printf '%s\n' "$IN_FLIGHT_ONE" > "$OVR/inflight-example_api.json"
run "$DISPATCH" example/app 7 --hub "$HUB" --apply --force
check "concurrency: --force dispatches anyway" code_is 0
check "concurrency: --force still claims first" claim_first

reset_fakes
echo '[{"number": 5, "comments": [{"body": "We could use orca-issue-orchestrator here."}]}]' > "$OVR/inflight-example_api.json"
run "$DISPATCH" example/app 7 --hub "$HUB"
check "concurrency: a comment that only mentions the marker does not count" code_is 0

for case_ in 'another author|mallory|.' 'wrong repo|orchestrator|.repo = "example/app"' \
  'wrong issue|orchestrator|.issue = 6' 'wrong hub|orchestrator|.hub = "other-hub"' 'wrong version|orchestrator|.v = 2'; do
  rest="${case_#*|}"
  reset_fakes
  in_flight_api "${rest%%|*}" "${rest#*|}" > "$OVR/inflight-example_api.json"
  run "$DISPATCH" example/app 7 --hub "$HUB"
  check "concurrency: a forged Mapping block (${case_%%|*}) does not count" code_is 0
  check "concurrency: a forged Mapping block (${case_%%|*}) is reported" out_has "example/api#5: ignoring a Mapping block"
done

reset_fakes
printf '%s\n' "$IN_FLIGHT_ONE" > "$OVR/inflight-example_api.json"
touch "$OVR/user.json.fail"
run "$DISPATCH" example/app 7 --hub "$HUB" --apply --force
check "concurrency: an unknown login refuses (fail closed)" code_is 1
check "concurrency: an unknown login claims nothing" no_mutation

reset_fakes
printf 'not json\n' > "$OVR/inflight-example_api.json"
run "$DISPATCH" example/app 7 --hub "$HUB" --apply
check "concurrency: a failed count refuses (fail closed)" code_is 1
check "concurrency: a failed count claims nothing" no_mutation

# More in-flight Issues than one page holds: the count reads every page.
reset_fakes
jq -c '[{number: 4, comments: [{author: {login: "someone"}, body: "orca-issue-orchestrator, in passing"}]}] + .' \
  <<< "$IN_FLIGHT_ONE" > "$OVR/inflight-example_api.json"
export FAKE_PAGE_SIZE=1
run "$DISPATCH" example/app 7 --hub "$HUB" --apply
check "concurrency, one Issue per page: the in-flight Issue on page 2 counts" code_is 1
check "concurrency, one Issue per page: nothing is claimed" no_mutation

reset_fakes
jq -n '{data: {search: {issueCount: 1500, pageInfo: {hasNextPage: false, endCursor: null}, nodes: []}}}' \
  > "$OVR/inflight-example_api.json"
run "$DISPATCH" example/app 7 --hub "$HUB" --apply
check "concurrency, search capped below the Issue count: refuses" code_is 1
check "concurrency, search capped below the Issue count: nothing is claimed" no_mutation

reset_fakes
jq '.concurrency = "two"' "$HUB/.orca-hub/hub.json" > "$WORK/hub.json" && cp "$HUB/.orca-hub/hub.json" "$WORK/hub.json.orig" && mv "$WORK/hub.json" "$HUB/.orca-hub/hub.json"
run "$DISPATCH" example/app 7 --hub "$HUB" --apply
mv "$WORK/hub.json.orig" "$HUB/.orca-hub/hub.json"
check "concurrency: a non-integer limit refuses" code_is 1
check "concurrency: a non-integer limit claims nothing" no_mutation

reset_fakes
run "$DISPATCH" example/app 9 --hub "$HUB" --apply
check "assigned: refuses an Issue that is already assigned" code_is 1
check "assigned: nothing is claimed" no_mutation

reset_fakes
run "$DISPATCH" example/other 1 --hub "$HUB" --apply
check "unknown repo: refuses a repo missing from hub.json" code_is 1
check "unknown repo: nothing is claimed" no_mutation

reset_fakes
echo '{"ok": true, "result": {"run": null}}' > "$OVR/orca-run-current.json"
run "$DISPATCH" example/app 7 --hub "$HUB" --apply
check "no Run: refuses before the claim" code_is 1
check "no Run: prints run-create" out_has "orca orchestration run-create"
check "no Run: nothing is claimed" no_mutation

# --- issue-dispatch.sh --receipt: Mapping comment ---------------------------------

reset_fakes
run "$DISPATCH" example/app 7 --hub "$HUB" --receipt "$FIXTURES/receipt-ready.json"
check "receipt dry-run: exits 0" code_is 0
check "receipt dry-run: prints worktree set with the full worktree id" \
  out_has_line 'orca worktree set --worktree id:repo-app-id::/path/to/worktrees/issue-7-add-login-page --issue 7 --json'
check "receipt dry-run: prints the comment" out_has_line "$COMMENT"
check "receipt dry-run: posts nothing" no_mutation

reset_fakes
run_stdin "$FIXTURES/receipt-ready.json" "$DISPATCH" example/app 7 --hub "$HUB" --receipt - --apply
check "receipt apply: exits 0" code_is 0
check "receipt apply: posts the Mapping comment" called "gh issue comment 7"
check "receipt apply: worktree set is never invoked" not_called "orca worktree set"
check "receipt apply: worker-start is never invoked" not_called "orca orchestration worker-start"
comment_first_line() { [ "$(head -1 "$FAKE_LOG.comment")" = '> *Posted by an AI orchestrator.*' ]; }
check "receipt apply: the comment starts with the AI disclaimer" comment_first_line
mapping_block() {
  sed -n 's/^<!-- orca-issue-orchestrator \(.*\) -->$/\1/p' "$FAKE_LOG.comment"
}
block_is() {
  mapping_block | jq -e '. == {
    v: 1, repo: "example/app", issue: 7, run_id: "run_test1", task_id: "task_test1",
    dispatch_id: "ctx_test1", worktree_id: "wt2:local:inst-7", worktree: "issue-7-add-login-page",
    branch: "issue-7-add-login-page", hub: "example-hub"
  }' >/dev/null
}
check "receipt apply: the JSON block has every field" block_is
check "receipt apply: the comment has no absolute path" no_abs_path "$FAKE_LOG.comment"
human_lines() {
  grep -qxF -- '- Worktree: `issue-7-add-login-page` (branch `issue-7-add-login-page`, base `main`)' "$FAKE_LOG.comment" &&
    grep -qxF -- '- Run `run_test1` / Task `task_test1` / Dispatch `ctx_test1`' "$FAKE_LOG.comment"
}
check "receipt apply: the comment has the human-readable lines" human_lines

reset_fakes
jq '.title = "Renamed after dispatch"' "$FIXTURES/issue-example_app-7.json" > "$OVR/issue-example_app-7.json"
run "$DISPATCH" example/app 7 --hub "$HUB" --receipt "$FIXTURES/receipt-ready.json" --apply
check "receipt apply, retitled Issue: the block keeps the started worktree name" \
  bash -c 'sed -n "s/^<!-- orca-issue-orchestrator \(.*\) -->\$/\1/p" "$FAKE_LOG.comment" | jq -e ".worktree == \"issue-7-add-login-page\"" >/dev/null'
check "receipt apply, retitled Issue: no recomputed name" \
  bash -c '! grep -qF issue-7-renamed "$FAKE_LOG.comment"'

reset_fakes
jq 'del(.result.worker.startOptions)' "$FIXTURES/receipt-ready.json" > "$WORK/receipt-no-name.json"
run "$DISPATCH" example/app 7 --hub "$HUB" --receipt "$WORK/receipt-no-name.json" --apply
check "receipt apply, no name in the receipt: the worktree name is the branch" \
  bash -c 'sed -n "s/^<!-- orca-issue-orchestrator \(.*\) -->\$/\1/p" "$FAKE_LOG.comment" | jq -e ".worktree == \"issue-7-add-login-page\"" >/dev/null'

reset_fakes
jq '.comments = [{"author": {"login": "orchestrator"}, "body": "Replaces \"dispatch_id\":\"ctx_test1\" <!-- orca-issue-orchestrator {\"v\":1,\"dispatch_id\":\"ctx_other\",\"hub\":\"example-hub\"} -->"}]' \
  "$FIXTURES/issue-example_app-7.json" > "$OVR/issue-example_app-7.json"
run "$DISPATCH" example/app 7 --hub "$HUB" --receipt "$FIXTURES/receipt-ready.json" --apply
check "receipt apply: a Mapping block of another Dispatch with prose naming ours does not stop it" called "gh issue comment 7"

reset_fakes
run "$DISPATCH" example/app 7 --hub . --receipt "$FIXTURES/receipt-ready.json" --apply
check "receipt apply: a relative --hub still posts the comment" called "gh issue comment 7"

reset_fakes
jq '.comments = [{"author": {"login": "orchestrator"}, "body": "> *Posted by an AI orchestrator.*\n\n<!-- orca-issue-orchestrator {\"v\":1,\"dispatch_id\":\"ctx_test1\",\"hub\":\"example-hub\"} -->"}]' \
  "$FIXTURES/issue-example_app-7.json" > "$OVR/issue-example_app-7.json"
run "$DISPATCH" example/app 7 --hub "$HUB" --receipt "$FIXTURES/receipt-ready.json" --apply
check "receipt apply: does not post a second Mapping comment for the same Dispatch" not_called "gh issue comment"

check "receipt apply: says the comment exists" out_has "already"

reset_fakes
jq '.comments = [range(100) | {author: {login: "someone"}, body: "+1"}]
    + [{"author": {"login": "orchestrator"}, "body": "<!-- orca-issue-orchestrator {\"v\":1,\"dispatch_id\":\"ctx_test1\",\"hub\":\"example-hub\"} -->"}]' \
  "$FIXTURES/issue-example_app-7.json" > "$OVR/issue-example_app-7.json"
run "$DISPATCH" example/app 7 --hub "$HUB" --receipt "$FIXTURES/receipt-ready.json" --apply
check "receipt apply: a Mapping comment past the first page counts too" not_called "gh issue comment"

reset_fakes
jq '.comments = [{"author": {"login": "mallory"}, "body": "<!-- orca-issue-orchestrator {\"v\":1,\"dispatch_id\":\"ctx_test1\",\"hub\":\"example-hub\"} -->"}]' \
  "$FIXTURES/issue-example_app-7.json" > "$OVR/issue-example_app-7.json"
run "$DISPATCH" example/app 7 --hub "$HUB" --receipt "$FIXTURES/receipt-ready.json" --apply
check "receipt apply: a forged Mapping comment does not stop the real one" called "gh issue comment 7"

# --- issue-dispatch.sh --receipt: failed worker-start ------------------------------

reset_fakes
run "$DISPATCH" example/app 7 --hub "$HUB" --receipt "$FIXTURES/receipt-agent-readiness.json" --apply
check "agent_readiness: exits non-zero" bash -c '[ "$1" -ne 0 ]' _ "$CODE"
check "agent_readiness: prints the retry on the live terminal" \
  out_has_line 'orca orchestration worker-start --task task_test1 --retry-of ctx_test1 --terminal term_test1 --worktree id:repo-app-id::/path/to/worktrees/issue-7-add-login-page --timeout-ms 300000 --json'
check "agent_readiness: posts no comment" no_mutation

reset_fakes
run "$DISPATCH" example/app 7 --hub "$HUB" --receipt "$FIXTURES/receipt-setup-failed.json" --apply
check "other failure: exits non-zero" bash -c '[ "$1" -ne 0 ]' _ "$CODE"
check "other failure: names the failed stage" out_has "placement"
check "other failure: prints no retry" out_lacks "--retry-of"
check "other failure: posts no comment" no_mutation

# --- summary ------------------------------------------------------------------

summary
