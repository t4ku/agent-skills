#!/usr/bin/env bash
# Executable-boundary tests for scripts/issue-recover.sh.
#
# Same seam as tests/dispatch.test.sh (tests/helpers.sh). In flight on
# example/app: #12 with two Mapping blocks (latest Dispatch ctx_test12, which
# Orca reports succeeded, worktree linked) and #13 (Dispatch ctx_test13, which
# Orca does not know, no worktree). Both are in Run run_test12; the terminal is
# bound to run_test1.
#
# Usage: tests/recover.test.sh

# The bash -c snippets expand their variables in the child shell.
# shellcheck disable=SC2016

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh disable=SC1091
. "$SCRIPT_DIR/helpers.sh"
RECOVER="$SCRIPTS/issue-recover.sh"

RUN_USE='orca orchestration run-use --id run_test12 --json'

# run_json <args...>: like run, but OUT is stdout only (--json writes commands to stderr).
run_json() {
  OUT="$(cd "$HUB" && bash "$RECOVER" "$@" 2> /dev/null)"
}

in_flight_two() { cp "$FIXTURES/inflight-two-example_app.json" "$OVR/inflight-example_app.json"; }
# row <n> <jq test>: the --json row of Issue <n> satisfies the test.
row() { printf '%s' "$OUT" | jq -e --argjson n "$1" "first(.issues[] | select(.issue == \$n)) | $2" > /dev/null; }

# --- dry-run --------------------------------------------------------------------

reset_fakes
in_flight_two
run "$RECOVER" --hub "$HUB"
check "dry-run: exits 0" code_is 0
check "dry-run: prints run-use for the Run on the Issues" out_has_line "$RUN_USE"
check "dry-run: makes no mutation" no_mutation
check "dry-run: lists open Issues assigned to @me carrying the marker, every page" \
  bash -c 'jq -e "select(.[1]==\"api\" and index(\"graphql\") and index(\"--paginate\")) | map(select(startswith(\"q=\")))[0] | contains(\"is:issue\") and contains(\"is:open\") and contains(\"assignee:@me\") and contains(\"orca-issue-orchestrator\")" "$FAKE_LOG" >/dev/null'
check "dry-run: reads every configured repo" \
  bash -c 'jq -e "select(.[1]==\"api\" and index(\"graphql\")) | map(select(startswith(\"q=\")))[0] | contains(\"repo:example/api \")" "$FAKE_LOG" >/dev/null'
check "dry-run: reconciles with worker-list --run" called "orca orchestration worker-list --run run_test12"
check "dry-run: reconciles with worktree list" called "orca worktree list"
check "dry-run: names the Issue" out_has "example/app#12"
check "dry-run: names the Run, Task, and Dispatch" \
  bash -c 'printf "%s" "$1" | grep -q "run_test12" && printf "%s" "$1" | grep -q "task_test12" && printf "%s" "$1" | grep -q "ctx_test12"' _ "$OUT"
check "dry-run: uses the latest Mapping block, not the first" out_lacks "ctx_old12"
check "dry-run: names the worktree" out_has "wt2:local:inst-12"
check "dry-run: reports the reconciled state" out_has "succeeded"
check "dry-run: points a settled Issue at closeout" out_has "issue-closeout.sh example/app 12 succeeded"

# --- --json -----------------------------------------------------------------------

reset_fakes
in_flight_two
run_json --hub "$HUB" --json
check "json: valid, two Issues" bash -c 'printf "%s" "$1" | jq -e ".issues | length == 2" >/dev/null' _ "$OUT"
check "json: #12 latest block" row 12 '.run_id == "run_test12" and .task_id == "task_test12" and .dispatch_id == "ctx_test12"'
check "json: #12 worktree and branch" row 12 '.worktree_id == "wt2:local:inst-12" and .branch == "issue-12-add-password-reset"'
check "json: #12 worktree found and linked" row 12 '.worktree == "linked"'
check "json: #12 state succeeded" row 12 '.state == "succeeded"'
check "json: #12 worker row from worker-list" row 12 '.worker.terminalState == "retained" and .worker.outcome == "succeeded"'
check "json: #13 Orca has no worker" row 13 '.state == "unknown" and .worker == null'
check "json: #13 worktree missing" row 13 '.worktree == "missing"'
check "json: run-use command" bash -c 'printf "%s" "$1" | jq -e ".run_use == [\"orca\",\"orchestration\",\"run-use\",\"--id\",\"run_test12\",\"--json\"]" >/dev/null' _ "$OUT"

reset_fakes
in_flight_two
jq '.result.workers[0].workerState = "ready" | .result.workers[0].projection.outcome = "in_progress" | .result.workers[0].projection.liveness.verdict = "live"' \
  "$FIXTURES/orca-worker-list-run_test12.json" > "$OVR/orca-worker-list-run_test12.json"
run_json --hub "$HUB" --json
check "json: a live in-progress worker is working" row 12 '.state == "working"'
check "json: working: next is the loop's wait" row 12 '.next == ["orca","orchestration","check","--wait","--types","worker_done,escalation,question","--timeout-ms","570000","--json"]'

reset_fakes
in_flight_two
jq '.result.workers[0].projection.outcome = "failed"' \
  "$FIXTURES/orca-worker-list-run_test12.json" > "$OVR/orca-worker-list-run_test12.json"
run_json --hub "$HUB" --json
check "json: a failed worker is failed" row 12 '.state == "failed"'

reset_fakes
in_flight_two
jq '.result.worktrees[2].linkedIssue = null' "$FIXTURES/orca-worktree-list.json" > "$OVR/orca-worktree-list.json"
run "$RECOVER" --hub "$HUB"
check "unlinked worktree: prints worktree set by identity" \
  out_has "orca worktree set --worktree identity:wt2:local:inst-12 --issue 12 --json"

# --- --apply ----------------------------------------------------------------------

reset_fakes
in_flight_two
run "$RECOVER" --hub "$HUB" --apply
check "apply: exits 0" code_is 0
check "apply: the only mutation is run-use" bash -c '[ "$(mutations_of)" = "$1" ]' _ "$RUN_USE"
check "apply: never touches the Issue" not_called "gh issue edit"

reset_fakes
in_flight_two
echo '{"ok": true, "result": {"run": {"id": "run_test12"}}}' > "$OVR/orca-run-current.json"
run "$RECOVER" --hub "$HUB" --apply
check "already bound: exits 0" code_is 0
check "already bound: no run-use" no_mutation
check "already bound: says so" out_has "already bound"
check "already bound: still prints run-use" out_has_line "$RUN_USE"

reset_fakes
in_flight_two
touch "$OVR/orca-worktree-list.json.fail"
run "$RECOVER" --hub "$HUB" --apply
check "worktree list fails: refuses" code_is 1
check "worktree list fails: binds nothing" no_mutation

reset_fakes
in_flight_two
echo '{"ok": false, "error": {"code": "runtime_unavailable", "message": "Orca is not running"}}' > "$OVR/orca-worktree-list.json"
run "$RECOVER" --hub "$HUB" --apply
check "worktree list error envelope: refuses" code_is 1
check "worktree list error envelope: binds nothing" no_mutation
check "worktree list error envelope: shows the error" out_has "runtime_unavailable"
check "worktree list error envelope: never reports a worktree missing" out_lacks "missing"

reset_fakes
in_flight_two
echo '{"ok": true, "result": {"totalCount": 0}}' > "$OVR/orca-worktree-list.json"
run "$RECOVER" --hub "$HUB" --apply
check "worktree list without worktrees[]: refuses" code_is 1
check "worktree list without worktrees[]: binds nothing" no_mutation

reset_fakes
in_flight_two
echo 'not json' > "$OVR/orca-worktree-list.json"
run "$RECOVER" --hub "$HUB" --apply
check "worktree list not JSON: refuses" code_is 1
check "worktree list not JSON: binds nothing" no_mutation

reset_fakes
in_flight_two
touch "$OVR/orca-worker-list-run_test12.json.fail"
run "$RECOVER" --hub "$HUB" --apply
check "worker-list fails: refuses" code_is 1
check "worker-list fails: binds nothing" no_mutation
check "worker-list fails: names worker-list" out_has "worker-list --run run_test12"
check "worker-list fails: never reports the Issues as unknown" out_lacks "unknown"

reset_fakes
in_flight_two
touch "$OVR/orca-worker-list-run_test12.json.fail"
run "$RECOVER" --hub "$HUB" --json
check "worker-list fails, --json: refuses" code_is 1
check "worker-list fails, --json: prints no report" out_lacks '"issues"'

reset_fakes
in_flight_two
echo '{"ok": false, "error": {"code": "run_not_found", "message": "no such Run"}}' > "$OVR/orca-worker-list-run_test12.json"
run "$RECOVER" --hub "$HUB" --apply
check "worker-list error envelope: refuses" code_is 1
check "worker-list error envelope: binds nothing" no_mutation
check "worker-list error envelope: shows the error" out_has "run_not_found"
check "worker-list error envelope: never reports the Issues as unknown" out_lacks "unknown"

reset_fakes
in_flight_two
jq '.result.workers = null' "$FIXTURES/orca-worker-list-run_test12.json" > "$OVR/orca-worker-list-run_test12.json"
run "$RECOVER" --hub "$HUB" --apply
check "worker-list without workers[]: refuses" code_is 1
check "worker-list without workers[]: binds nothing" no_mutation

reset_fakes
in_flight_two
jq 'del(.result.page)' "$FIXTURES/orca-worker-list-run_test12.json" > "$OVR/orca-worker-list-run_test12.json"
run "$RECOVER" --hub "$HUB" --apply
check "worker-list without page: refuses" code_is 1
check "worker-list without page: binds nothing" no_mutation

reset_fakes
in_flight_two
jq '.result.page.hasMore = true | .result.page.nextCursor = null' \
  "$FIXTURES/orca-worker-list-run_test12.json" > "$OVR/orca-worker-list-run_test12.json"
run "$RECOVER" --hub "$HUB" --apply
check "worker-list hasMore without cursor: refuses" code_is 1
check "worker-list hasMore without cursor: binds nothing" no_mutation
check "worker-list hasMore without cursor: says so" out_has "nextCursor"

reset_fakes
in_flight_two
jq '.result.page.hasMore = true | .result.page.nextCursor = "c1"' \
  "$FIXTURES/orca-worker-list-run_test12.json" > "$OVR/orca-worker-list-run_test12.json"
ORCA_WORKER_PAGES_MAX=3 run "$RECOVER" --hub "$HUB" --apply
check "worker-list never ends: refuses at the page cap" code_is 1
check "worker-list never ends: binds nothing" no_mutation
check "worker-list never ends: names the cap" out_has "after 3 pages"
check "worker-list never ends: stops at the cap" \
  bash -c '[ "$(calls | grep -c "^orca orchestration worker-list")" -eq 3 ]'

reset_fakes
jq '(.[] | select(.number == 12) | .comments) += [{"author": {"login": "orchestrator"}, "body": "<!-- orca-issue-orchestrator-closeout {\"v\":1,\"dispatch_id\":\"ctx_test12\",\"outcome\":\"succeeded\",\"hub\":\"example-hub\"} -->"}]' \
  "$FIXTURES/inflight-two-example_app.json" > "$OVR/inflight-example_app.json"
run_json --hub "$HUB" --json
check "closed out: state closed-out, next is the audit" row 12 '.state == "closed-out" and (.next[0] | endswith("issue-audit.sh"))'

reset_fakes
jq '(.[] | select(.number == 12) | .comments) += [{"author": {"login": "orchestrator"}, "body": "<!-- orca-issue-orchestrator-closeout {\"v\":1,\"dispatch_id\":\"ctx_test12\",\"outcome\":\"succeeded\",\"hub\":\"other-hub\"} -->"}]' \
  "$FIXTURES/inflight-two-example_app.json" > "$OVR/inflight-example_app.json"
run_json --hub "$HUB" --json
check "closeout marker of another Hub: not closed out" row 12 '.state == "succeeded"'

reset_fakes
jq '(.[] | select(.number == 13) | .comments[0].body) |= sub("run_test12"; "run_other")' \
  "$FIXTURES/inflight-two-example_app.json" > "$OVR/inflight-example_app.json"
echo '{"ok": true, "result": {"workers": [], "page": {"hasMore": false}}}' > "$OVR/orca-worker-list-run_other.json"
run "$RECOVER" --hub "$HUB" --apply
check "two Runs: refuses to pick one" code_is 1
check "two Runs: binds nothing" no_mutation
check "two Runs: prints both run-use commands" \
  bash -c 'printf "%s\n" "$1" | grep -qxF "$2" && printf "%s\n" "$1" | grep -qxF "orca orchestration run-use --id run_other --json"' _ "$OUT" "$RUN_USE"

reset_fakes
jq '(.[] | select(.number == 12) | .comments) += [{"author": {"login": "orchestrator"}, "body": "Supersedes \"dispatch_id\":\"ctx_test12\" <!-- orca-issue-orchestrator-closeout {\"v\":1,\"dispatch_id\":\"ctx_old12\",\"outcome\":\"failed\",\"hub\":\"example-hub\"} -->"}]' \
  "$FIXTURES/inflight-two-example_app.json" > "$OVR/inflight-example_app.json"
run_json --hub "$HUB" --json
check "closeout marker of another Dispatch, prose naming ours: not closed out" row 12 '.state == "succeeded"'

# --- every page of the in-flight search ---------------------------------------------

reset_fakes
in_flight_two
export FAKE_PAGE_SIZE=1
run_json --hub "$HUB" --json
check "one Issue per page: both Issues are recovered" \
  bash -c 'printf "%s" "$1" | jq -e "[.issues[].issue] == [12, 13]" >/dev/null' _ "$OUT"

reset_fakes
jq '(.[] | select(.number == 13) | .comments) |= [range(120) | {author: {login: "someone"}, body: "+1"}] + .' \
  "$FIXTURES/inflight-two-example_app.json" > "$OVR/inflight-example_app.json"
export FAKE_PAGE_SIZE=50
run_json --hub "$HUB" --json
check "Mapping block after 120 comments: the Issue is recovered" row 13 '.dispatch_id == "ctx_test13"'

reset_fakes
jq -n '{data: {search: {issueCount: 1500, pageInfo: {hasNextPage: false, endCursor: null}, nodes: []}}}' \
  > "$OVR/inflight-example_app.json"
run "$RECOVER" --hub "$HUB" --apply
check "search capped below the Issue count: refuses" code_is 1
check "search capped below the Issue count: never says nothing is in flight" out_lacks "No in-flight Issues"

# --- Mapping trust ----------------------------------------------------------------

# forge_12 <author> <jq update of the block>: append to #12 a comment by
# <author> whose Mapping block names Run run_evil, then is updated.
forge_12() {
  jq --arg a "$1" --argjson b "$(jq -cn '{v: 1, repo: "example/app", issue: 12, run_id: "run_evil", task_id: "task_evil",
      dispatch_id: "ctx_evil", worktree_id: "wt2:local:evil", branch: "evil", hub: "example-hub"}' | jq -c "$2")" \
    '(.[] | select(.number == 12) | .comments) += [{author: {login: $a},
      body: ("<!-- orca-issue-orchestrator " + ($b | tojson) + " -->")}]' \
    "$FIXTURES/inflight-two-example_app.json" > "$OVR/inflight-example_app.json"
}

reset_fakes
forge_12 mallory .
run_json --hub "$HUB" --json
check "forged marker from another author: #12 keeps Dispatch ctx_test12" row 12 '.dispatch_id == "ctx_test12" and .run_id == "run_test12"'
check "forged marker from another author: rebinds to the real Run" \
  bash -c 'printf "%s" "$1" | jq -e ".runs == [\"run_test12\"]" >/dev/null' _ "$OUT"

for case_ in 'wrong repo|.repo = "other/app"' 'wrong issue|.issue = 99' \
  'wrong hub|.hub = "other-hub"' 'wrong version|.v = 2'; do
  reset_fakes
  forge_12 orchestrator "${case_#*|}"
  run_json --hub "$HUB" --json
  check "forged marker (${case_%%|*}): #12 keeps Dispatch ctx_test12" row 12 '.dispatch_id == "ctx_test12" and .run_id == "run_test12"'
done

reset_fakes
jq '(.[] | select(.number == 13) | .comments[0].author.login) = "mallory"' \
  "$FIXTURES/inflight-two-example_app.json" > "$OVR/inflight-example_app.json"
run_json --hub "$HUB" --json
check "only a forged marker: the Issue is not in flight" \
  bash -c 'printf "%s" "$1" | jq -e "[.issues[].issue] == [12]" >/dev/null' _ "$OUT"

reset_fakes
run "$RECOVER" --hub "$HUB" --apply
check "nothing in flight: exits 0" code_is 0
check "nothing in flight: says so" out_has "No in-flight Issues"
check "nothing in flight: no mutation" no_mutation

reset_fakes
printf 'not json\n' > "$OVR/inflight-example_app.json"
run "$RECOVER" --hub "$HUB" --apply
check "gh failure: refuses" code_is 1
check "gh failure: no mutation" no_mutation

summary
