#!/usr/bin/env bash
# Executable-boundary tests for scripts/issue-closeout.sh and scripts/issue-audit.sh.
#
# Same seam as tests/dispatch.test.sh: fake `gh` and `orca` first on PATH,
# assertions on stdout, the exit code, and the call log (tests/helpers.sh).
# Fixture Issue example/app#12 carries two Mapping blocks; the latest is
# Dispatch ctx_test12. tests/fixtures/check-worker-*.json are `check --json`
# batches with heartbeats and another Dispatch's worker_done mixed in.
#
# Usage: tests/closeout.test.sh

# The bash -c snippets expand their variables in the child shell.
# shellcheck disable=SC2016

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh disable=SC1091
. "$SCRIPT_DIR/helpers.sh"
CLOSEOUT="$SCRIPTS/issue-closeout.sh"
AUDIT="$SCRIPTS/issue-audit.sh"

COMMENT='gh issue comment 12 -R example/app --body-file -'
LABEL='gh issue edit 12 -R example/app --add-label needs-info --remove-label ready-for-agent'
UNASSIGN='gh issue edit 12 -R example/app --remove-assignee @me'
RELEASE='orca orchestration worker-release --dispatch ctx_test12 --json'
NEEDS='Name the mail provider and where its credentials live.'

never_closes() { not_called "gh issue close" && not_called "orca orchestration task-update"; }
comment_has() { grep -qF -- "$1" "$FAKE_LOG.comment"; }
comment_lacks() { ! comment_has "$1"; }
comment_first_line() { [ "$(head -1 "$FAKE_LOG.comment")" = '> *Posted by an AI orchestrator.*' ]; }

# --- success ------------------------------------------------------------------

reset_fakes
run "$CLOSEOUT" example/app 12 succeeded "$FIXTURES/check-worker-done.json" --hub "$HUB"
check "success dry-run: exits 0" code_is 0
check "success dry-run: prints the comment" out_has_line "$COMMENT"
check "success dry-run: prints worker-release" out_has_line "$RELEASE"
check "success dry-run: makes no mutation" no_mutation
check "success dry-run: shows the comment body" out_has "https://github.com/example/app/pull/40"

reset_fakes
run "$CLOSEOUT" example/app 12 succeeded "$FIXTURES/check-worker-done.json" --hub "$HUB" --apply
check "success apply: exits 0" code_is 0
check "success apply: exactly one mutation, the comment" bash -c '[ "$(mutations_of)" = "$1" ]' _ "$COMMENT"
check "success apply: no label or assignee change" not_called "gh issue edit"
check "success apply: never closes the Issue or completes the Task" never_closes
check "success apply: prints worker-release" out_has_line "$RELEASE"
check "success apply: worker-release is never invoked" not_called "orca orchestration worker-release"
check "success apply: the comment starts with the AI disclaimer" comment_first_line
check "success apply: the comment has the PR link" comment_has "https://github.com/example/app/pull/40"
check "success apply: the comment has the summary" comment_has "Added the password reset flow and its mail template."
check "success apply: the comment lists the files modified" comment_has '- `src/reset.test.ts`'
check "success apply: heartbeats and other Dispatches are ignored" comment_lacks "other.txt"
check "success apply: the comment has no local path" no_abs_path "$FAKE_LOG.comment"

reset_fakes
printf 'Added the reset flow. Tests pass. Nothing left.\n' > "$WORK/summary.txt"
run "$CLOSEOUT" example/app 12 succeeded "$WORK/summary.txt" --hub "$HUB" --apply --files src/reset.ts,src/mail.ts
check "plain summary: exits 0" code_is 0
check "plain summary: finds the open PR by the Mapping branch" comment_has "https://github.com/example/app/pull/40"
check "plain summary: --files lists the files" comment_has '- `src/mail.ts`'
check "plain summary: the summary is the file" comment_has "Added the reset flow. Tests pass. Nothing left."
check "plain summary: validates the PR it found" called "gh pr view 40 -R example/app"
check "success apply: the files section is always rendered" comment_has "**Files modified:**"

reset_fakes
echo '[]' > "$OVR/prs-example_app.json"
run "$CLOSEOUT" example/app 12 succeeded "$WORK/summary.txt" --hub "$HUB" --apply --files src/reset.ts
check "no PR: success without an open PR refuses" code_is 1
check "no PR: posts nothing" no_mutation

reset_fakes
run_stdin "$FIXTURES/check-worker-done.json" "$CLOSEOUT" example/app 12 succeeded - --hub "$HUB" --apply
check "stdin: reads the batch from -" comment_has "https://github.com/example/app/pull/40"

# --- PR validation: every PR, whatever its source, must be open, here, on the branch ---

reset_fakes
run "$CLOSEOUT" example/app 12 succeeded "$FIXTURES/check-worker-done.json" --hub "$HUB" --apply
check "PR from the summary: validated with gh pr view" called "gh pr view 40 -R example/app"

reset_fakes
run "$CLOSEOUT" example/app 12 succeeded "$WORK/summary.txt" --hub "$HUB" --apply --files src/reset.ts \
  --pr https://github.com/example/app/pull/41
check "--pr merged: refuses" code_is 1
check "--pr merged: names the state" out_has "MERGED"
check "--pr merged: posts nothing" no_mutation

reset_fakes
jq '.headRefName = "someone-else"' "$FIXTURES/pr-example_app-40.json" > "$OVR/pr-example_app-40.json"
run "$CLOSEOUT" example/app 12 succeeded "$WORK/summary.txt" --hub "$HUB" --apply --files src/reset.ts \
  --pr https://github.com/example/app/pull/40
check "--pr other head branch: refuses" code_is 1
check "--pr other head branch: names both branches" \
  bash -c 'printf "%s" "$1" | grep -qF someone-else && printf "%s" "$1" | grep -qF issue-12-add-password-reset' _ "$OUT"
check "--pr other head branch: posts nothing" no_mutation

reset_fakes
jq '.isCrossRepository = true | .headRepositoryOwner.login = "forker"' "$FIXTURES/pr-example_app-40.json" > "$OVR/pr-example_app-40.json"
run "$CLOSEOUT" example/app 12 succeeded "$WORK/summary.txt" --hub "$HUB" --apply --files src/reset.ts --pr 40
check "--pr from a fork: refuses" code_is 1
check "--pr from a fork: names the head repository" out_has "forker"
check "--pr from a fork: posts nothing" no_mutation

reset_fakes
run "$CLOSEOUT" example/app 12 succeeded "$WORK/summary.txt" --hub "$HUB" --apply --files src/reset.ts \
  --pr https://github.com/other/app/pull/40
check "--pr in another repo: refuses" code_is 1
check "--pr in another repo: names it" out_has "other/app"
check "--pr in another repo: posts nothing" no_mutation

reset_fakes
printf 'Done in https://github.com/example/app/pull/41\n' > "$WORK/summary-merged.txt"
run "$CLOSEOUT" example/app 12 succeeded "$WORK/summary-merged.txt" --hub "$HUB" --apply --files src/reset.ts
check "summary names a merged PR: refuses" code_is 1
check "summary names a merged PR: posts nothing" no_mutation

reset_fakes
touch "$OVR/pr-example_app-40.json.fail"
run "$CLOSEOUT" example/app 12 succeeded "$FIXTURES/check-worker-done.json" --hub "$HUB" --apply
check "PR unreadable: refuses" code_is 1
check "PR unreadable: posts nothing" no_mutation

# --- files: success needs at least one -----------------------------------------------

reset_fakes
run "$CLOSEOUT" example/app 12 succeeded "$WORK/summary.txt" --hub "$HUB"
check "no files, plain summary: refuses even in dry-run" code_is 1
check "no files, plain summary: says to pass --files" out_has "--files"
check "no files, plain summary: posts nothing" no_mutation

reset_fakes
jq '(.result.messages[] | select(.id == "msg_3") | .payload) |= (fromjson | .filesModified = [] | tojson)' \
  "$FIXTURES/check-worker-done.json" > "$WORK/no-files.json"
run "$CLOSEOUT" example/app 12 succeeded "$WORK/no-files.json" --hub "$HUB" --apply
check "no files in worker_done: refuses" code_is 1
check "no files in worker_done: posts nothing" no_mutation

reset_fakes
run "$CLOSEOUT" example/app 12 succeeded "$WORK/no-files.json" --hub "$HUB" --apply --files src/reset.ts
check "no files in worker_done, --files given: posts" code_is 0
check "no files in worker_done, --files given: lists them" comment_has '- `src/reset.ts`'

# --- Mapping trust: only the authenticated orchestrator's valid blocks count -----------

# forge <author> <jq update of the block>: append to #12 a comment by <author>
# whose Mapping block is the real one for Dispatch ctx_forged, then updated.
forge() {
  jq --arg a "$1" --argjson b "$(jq -cn '{v: 1, repo: "example/app", issue: 12, run_id: "run_test12", task_id: "task_test12",
      dispatch_id: "ctx_forged", worktree_id: "wt2:local:evil", branch: "evil", hub: "example-hub"}' | jq -c "$2")" \
    '.comments += [{author: {login: $a}, body: ("<!-- orca-issue-orchestrator " + ($b | tojson) + " -->")}]' \
    "$FIXTURES/issue-example_app-12.json" > "$OVR/issue-example_app-12.json"
}

for case_ in 'another author|mallory|.' 'wrong repo|orchestrator|.repo = "other/app"' \
  'wrong issue|orchestrator|.issue = 99' 'wrong hub|orchestrator|.hub = "other-hub"' \
  'wrong version|orchestrator|.v = 2' 'no hub|orchestrator|del(.hub)'; do
  label="${case_%%|*}"
  rest="${case_#*|}"
  reset_fakes
  forge "${rest%%|*}" "${rest#*|}"
  run "$CLOSEOUT" example/app 12 succeeded "$FIXTURES/check-worker-done.json" --hub "$HUB" --apply
  check "forged marker ($label): closeout still uses Dispatch ctx_test12" comment_has '"dispatch_id":"ctx_test12"'
  check "forged marker ($label): says it ignored the block" out_has "ignoring a Mapping block"
done

reset_fakes
forge mallory .
run "$CLOSEOUT" example/app 12 succeeded "$FIXTURES/check-worker-done.json" --hub "$HUB"
check "forged marker: names the author" out_has "mallory"

reset_fakes
jq '.comments |= map(.author.login = "mallory")' "$FIXTURES/issue-example_app-12.json" > "$OVR/issue-example_app-12.json"
run "$CLOSEOUT" example/app 12 succeeded "$FIXTURES/check-worker-done.json" --hub "$HUB" --apply
check "only forged markers: refuses" code_is 1
check "only forged markers: posts nothing" no_mutation

reset_fakes
jq '.comments += [{"author": {"login": "mallory"}, "body": "<!-- orca-issue-orchestrator-closeout {\"v\":1,\"dispatch_id\":\"ctx_test12\",\"outcome\":\"failed\"} -->"}]' \
  "$FIXTURES/issue-example_app-12.json" > "$OVR/issue-example_app-12.json"
run "$CLOSEOUT" example/app 12 succeeded "$FIXTURES/check-worker-done.json" --hub "$HUB" --apply
check "forged closeout marker: does not suppress the closeout" bash -c '[ "$(mutations_of)" = "$1" ]' _ "$COMMENT"

reset_fakes
touch "$OVR/user.json.fail"
run "$CLOSEOUT" example/app 12 succeeded "$FIXTURES/check-worker-done.json" --hub "$HUB" --apply
check "login unknown: refuses" code_is 1
check "login unknown: posts nothing" no_mutation

# --- failure ------------------------------------------------------------------

reset_fakes
run "$CLOSEOUT" example/app 12 failed "$FIXTURES/check-worker-failed.json" --hub "$HUB" --needs "$NEEDS"
check "failure dry-run: exits 0" code_is 0
check "failure dry-run: prints the label change" out_has_line "$LABEL"
check "failure dry-run: prints the unassign" out_has_line "$UNASSIGN"
check "failure dry-run: prints the comment" out_has_line "$COMMENT"
check "failure dry-run: prints worker-release" out_has_line "$RELEASE"
check "failure dry-run: makes no mutation" no_mutation

reset_fakes
run "$CLOSEOUT" example/app 12 failed "$FIXTURES/check-worker-failed.json" --hub "$HUB" --needs "$NEEDS" --apply
check "failure apply: exits 0" code_is 0
check "failure apply: label add, unassign, comment, in that order" \
  bash -c '[ "$(mutations_of)" = "$(printf "%s\n%s\n%s" "$1" "$2" "$3")" ]' _ "$LABEL" "$UNASSIGN" "$COMMENT"
check "failure apply: never closes the Issue or completes the Task" never_closes
check "failure apply: worker-release is printed, never invoked" \
  bash -c 'printf "%s\n" "$1" | grep -qxF "$2"' _ "$OUT" "$RELEASE"
check "failure apply: worker-release is not invoked" not_called "orca orchestration worker-release"
check "failure apply: the comment starts with the AI disclaimer" comment_first_line
check "failure apply: the comment has the template heading" comment_has "## Worker report: failed"
check "failure apply: what was attempted" \
  comment_has "**What was attempted:** Tried to add the reset flow. The mail provider is not named in the Issue. No PR was opened."
check "failure apply: evidence" comment_has "**Evidence:**"
check "failure apply: what a human must supply" comment_has "**What is needed from a human:** $NEEDS"
check "failure apply: the worktree is kept" comment_has '`issue-12-add-password-reset`'
check "failure apply: the report path does not leak" no_abs_path "$FAKE_LOG.comment"

reset_fakes
run "$CLOSEOUT" example/app 12 failed "$FIXTURES/check-worker-failed.json" --hub "$HUB" --apply
check "failure without --needs: refuses under --apply" code_is 1
check "failure without --needs: changes nothing" no_mutation

# --- refusals -------------------------------------------------------------------

reset_fakes
run "$CLOSEOUT" example/app 12 failed "$FIXTURES/check-worker-done.json" --hub "$HUB" --needs "$NEEDS" --apply
check "outcome mismatch: refuses" code_is 1
check "outcome mismatch: says so" out_has "succeeded"
check "outcome mismatch: changes nothing" no_mutation

reset_fakes
jq '.result.messages |= map(select(.type == "heartbeat"))' "$FIXTURES/check-worker-done.json" > "$WORK/heartbeats.json"
run "$CLOSEOUT" example/app 12 succeeded "$WORK/heartbeats.json" --hub "$HUB" --apply
check "heartbeats only: refuses" code_is 1
check "heartbeats only: names the Dispatch" out_has "ctx_test12"
check "heartbeats only: changes nothing" no_mutation

reset_fakes
run "$CLOSEOUT" example/app 7 succeeded "$WORK/summary.txt" --hub "$HUB" --apply
check "no Mapping comment: refuses" code_is 1
check "no Mapping comment: changes nothing" no_mutation

reset_fakes
printf 'Done; see %s/notes.md and https://github.com/example/app/pull/40\n' "$HOME" > "$WORK/leaky.txt"
run "$CLOSEOUT" example/app 12 succeeded "$WORK/leaky.txt" --hub "$HUB" --apply --files src/reset.ts
check "local path: refuses to post" code_is 1
check "local path: changes nothing" no_mutation

reset_fakes
jq '.comments += [{"author": {"login": "orchestrator"}, "body": "> *Posted by an AI orchestrator.*\n\n<!-- orca-issue-orchestrator-closeout {\"v\":1,\"dispatch_id\":\"ctx_test12\",\"outcome\":\"failed\"} -->"}]' \
  "$FIXTURES/issue-example_app-12.json" > "$OVR/issue-example_app-12.json"
run "$CLOSEOUT" example/app 12 failed "$FIXTURES/check-worker-failed.json" --hub "$HUB" --needs "$NEEDS" --apply
check "already closed out: exits 0" code_is 0
check "already closed out: changes nothing" no_mutation
check "already closed out: still prints worker-release" out_has_line "$RELEASE"

reset_fakes
jq '.labels = []' "$FIXTURES/issue-example_app-12.json" > "$OVR/issue-example_app-12.json"
run "$CLOSEOUT" example/app 12 failed "$FIXTURES/check-worker-failed.json" --hub "$HUB" --needs "$NEEDS" --apply
check "no ready-for-agent label: only adds needs-info" \
  bash -c '[ "$(mutations_of | head -1)" = "gh issue edit 12 -R example/app --add-label needs-info" ]'

reset_fakes
jq '.comments += [{"author": {"login": "orchestrator"}, "body": "<!-- orca-issue-orchestrator-closeout {\"v\":1,\"dispatch_id\":\"ctx_test12\",\"outcome\":\"succeeded\"} -->"}]' \
  "$FIXTURES/issue-example_app-12.json" > "$OVR/issue-example_app-12.json"
echo '[]' > "$OVR/prs-example_app.json"
run "$CLOSEOUT" example/app 12 succeeded "$WORK/summary.txt" --hub "$HUB" --apply
check "rerun after the merge: exits 0" code_is 0
check "rerun after the merge: changes nothing" no_mutation

reset_fakes
run "$CLOSEOUT" example/app 12 finished "$WORK/summary.txt" --hub "$HUB"
check "bad outcome: refuses" code_is 1

# --- issue-audit.sh: merged PR, Issue still open ------------------------------------

NOTICE='example/app: PR #41 merged, Issue #13 still open: close it by hand'

reset_fakes
cp "$FIXTURES/inflight-two-example_app.json" "$OVR/inflight-example_app.json"
run "$AUDIT" --hub "$HUB"
check "audit dry-run: exits 0" code_is 0
check "audit dry-run: prints the notice" out_has_line "$NOTICE"
check "audit dry-run: an open PR is not reported" out_lacks "Issue #12"
check "audit dry-run: #130 does not match #13" out_lacks "PR #42"
check "audit dry-run: prints the comment it would post" out_has_line 'gh issue comment 13 -R example/app --body-file -'
check "audit dry-run: makes no mutation" no_mutation

reset_fakes
cp "$FIXTURES/inflight-two-example_app.json" "$OVR/inflight-example_app.json"
run "$AUDIT" --hub "$HUB" --apply
check "audit apply: exits 0" code_is 0
check "audit apply: exactly one mutation, the comment on #13" \
  bash -c '[ "$(mutations_of)" = "gh issue comment 13 -R example/app --body-file -" ]'
check "audit apply: never closes the Issue" never_closes
check "audit apply: the comment starts with the AI disclaimer" \
  bash -c '[ "$(head -1 "$FAKE_LOG.comment")" = "> *Posted by an AI orchestrator.*" ]'
check "audit apply: the comment carries the notice" comment_has "PR #41 merged, Issue #13 still open: close it by hand"

reset_fakes
jq '(.[] | select(.number == 13) | .comments) += [{"author": {"login": "orchestrator"}, "body": "<!-- orca-issue-orchestrator-audit {\"v\":1,\"pr\":41} -->"}]' \
  "$FIXTURES/inflight-two-example_app.json" > "$OVR/inflight-example_app.json"
run "$AUDIT" --hub "$HUB" --apply
check "audit apply: does not post the same notice twice" no_mutation
check "audit apply: still prints the notice" out_has_line "$NOTICE"

reset_fakes
jq '(.[] | select(.number == 13) | .comments) += [{"author": {"login": "mallory"}, "body": "<!-- orca-issue-orchestrator-audit {\"v\":1,\"pr\":41} -->"}]' \
  "$FIXTURES/inflight-two-example_app.json" > "$OVR/inflight-example_app.json"
run "$AUDIT" --hub "$HUB" --apply
check "audit apply: a forged notice marker does not suppress the notice" \
  bash -c '[ "$(mutations_of)" = "gh issue comment 13 -R example/app --body-file -" ]'

reset_fakes
jq '(.[] | select(.number == 13) | .comments[0].author.login) = "mallory"' \
  "$FIXTURES/inflight-two-example_app.json" > "$OVR/inflight-example_app.json"
run "$AUDIT" --hub "$HUB" --apply
check "audit: an Issue whose only Mapping block is forged is not in flight" out_lacks "Issue #13"
check "audit: posts nothing for it" no_mutation

reset_fakes
jq '(.[] | select(.number == 13) | .comments[0].body) |= sub("example-hub"; "other-hub")' \
  "$FIXTURES/inflight-two-example_app.json" > "$OVR/inflight-example_app.json"
run "$AUDIT" --hub "$HUB"
check "audit: an Issue of another hub is not in flight" out_lacks "Issue #13"

reset_fakes
run "$AUDIT" --hub "$HUB"
check "audit: nothing in flight exits 0" code_is 0
check "audit: nothing in flight says so" out_has "No merged PR"

summary
