# Issue sync

How the Orchestrator moves a GitHub Issue through an Orca Worker and back: Frontier, Claim, Spec, dispatch, Mapping comment, closeout, recovery. Vocabulary: [CONTEXT.md](../CONTEXT.md). Hub config: [hub-json.md](hub-json.md).

Every write goes through an Orchestrator command. Each one prints what it would do and acts only with `--apply`: preview, read the plan, then apply.

## Rules

- Claim (assign `@me`) before any other write on an Issue.
- Every comment starts with `> *Posted by an AI orchestrator.*`
- Public comments carry the `hub_id`, never a local path.
- Never close an Issue, merge a PR, or push. GitHub may not link `Closes #123` from the PR body (it has happened: `closingIssuesReferences` stayed empty), so never assume the Issue closes on merge; a human checks.
- Never run `task-update --status completed`; a valid `worker_done` settles the Task.
- Workers never write to Issues; their only GitHub write is `gh pr create`.

## Frontier

The Frontier is every open `ready-for-agent` Issue that is unblocked (`issue_dependencies_summary.blocked_by == 0` in the REST API) and unassigned, across every repo in `hub.json`. Pull requests are excluded.

```sh
scripts/frontier.sh            # tab-separated: <owner>/<repo>#<n>  <title>  <url>
scripts/frontier.sh --json     # [{repo, number, title, url}]
```

Order: repos as listed in `hub.json`, then Issue number ascending. `frontier.sh` only reads. Take an Issue from it only when a human asks ("take the next one"); there is no resident loop.

## Dispatch

`scripts/issue-dispatch.sh` runs in two steps, because the Mapping comment needs ids that exist only after `worker-start`, and the script never starts a Worker itself.

### Step 1: claim and create the Task

```sh
scripts/issue-dispatch.sh <owner>/<repo> 123            # preview
scripts/issue-dispatch.sh <owner>/<repo> 123 --apply    # act
```

Before any write it checks, and refuses (exit 1) when one fails:

1. `<owner>/<repo>` is in `hub.json` `repos[]`.
2. The Issue is open and has no assignee.
3. **Concurrency**: the open Issues assigned to `@me` whose comments hold a Mapping block, summed over every configured repo, are fewer than `concurrency` (default 1). `--force` dispatches anyway.
4. An Orca repo matches: `orca repo list --json`, `.result.repos[]` with `.gitRemoteIdentity.canonicalKey == "github.com/<owner>/<repo>"`, used as `id:<repo-id>`.
5. A Run is bound to this terminal (`orca orchestration run-current --json`). Without one, `--apply` refuses and prints `orca orchestration run-create`. One Run per Orchestrator session.

With `--apply` it then, in this order:

1. **Claims**: `gh issue edit 123 -R <owner>/<repo> --add-assignee @me`.
2. **Creates the Task**: `orca orchestration task-create --task-title "#123 <Issue title>" --spec <Spec> --json`.
3. **Prints, never runs**, the Worker start and the worktree link:

   ```sh
   orca orchestration worker-start --task <task_id> --worktree new-top-level --repo id:<repo-id> \
     --name issue-123-<slug> --base-branch <base> --agent claude --setup skip --timeout-ms 300000 --json
   orca worktree set --worktree id:<worktree_id> --issue 123 --json
   ```

   `<slug>` is the first three ASCII words of the title. `<base>` is the repo's `base_branch` in `hub.json`, else its default branch. Keep `--timeout-ms 300000`: with Orca's default timeout `worker-start` has failed at `agent_readiness` while the terminal was in fact live.

If the claim fails nothing else happens. If `task-create` fails after the claim, the Issue stays assigned to you: fix the cause and create the Task by hand, or unassign.

### Step 2: start the Worker, link the worktree, post the Mapping comment

Run the printed `worker-start` yourself and pipe its JSON receipt into step 2:

```sh
orca orchestration worker-start --task <task_id> ... --json \
  | scripts/issue-dispatch.sh <owner>/<repo> 123 --receipt - --apply
```

(`--receipt <file>` reads a saved receipt instead.) Step 2:

- Reads `dispatchId`, `taskId`, `runId`, and the worktree id (`<repo-id>::<path>`) from the receipt, then the worktree's `identity.key` and branch from `orca worktree list --json`.
- Prints `orca worktree set --worktree id:<worktree_id> --issue 123 --json`; run it yourself so Orca's sidebar shows the Issue.
- Posts the Mapping comment with `gh issue comment 123 -R <owner>/<repo> --body-file -`, unless a Mapping comment for the same Dispatch is already on the Issue. It refuses to post a body that contains the Hub folder path, your home directory, or a `::/` worktree path.

**When `worker-start` failed** (exit 3, no comment posted):

- `failedStage == "agent_readiness"` and `residualResources[]` holds the agent terminal: check it with `orca orchestration worker-show --dispatch <dispatch_id> --json`; if the agent is up, run the printed retry, then feed its receipt to step 2 again:

  ```sh
  orca orchestration worker-start --task <task_id> --retry-of <dispatch_id> --terminal <terminal_handle> \
    --worktree id:<worktree_id> --timeout-ms 300000 --json
  ```

- Any other failed stage: do not relaunch. Follow the receipt's recovery commands and `references/recovery-and-cleanup.md` in `orca skills get orchestration --full`.

## Spec template

The Task body handed to the Worker. `issue-dispatch.sh` builds it; the Issue body is pasted verbatim (comments are not), so no interpretation sits between the Issue and the Worker. Per-repo `constraints[]` from `hub.json` are appended to Constraints.

````
Issue: https://github.com/<owner>/<repo>/issues/123
Task: #123 <Issue title>

## Target
<owner>/<repo>, worktree issue-123-<slug> (a fresh top-level worktree; Orca derives the branch from this name), base <base>

## Change
<the Issue body, verbatim>

## Constraints
- Do not touch the Issue (labels, assignee, comments, close). The only GitHub write you make is `gh pr create`.
- Stay inside this worktree. Do not edit other worktrees or the Hub folder.
- <each constraints[] entry of this repo in hub.json>

## How to work
- Follow `/implement`: `/tdd` at agreed seams, typecheck often, full test suite once at the end, `/code-review`, then commit to the current branch.
- Open a PR: `gh pr create --title "#123 <Issue title>" --body-file <file>` with `Closes #123` as the first line of the body.

## Done
- Send `worker_done` exactly once from this terminal: `--outcome succeeded` only if the PR is open, otherwise `--outcome failed`. Three-sentence summary, include the PR URL, `--files-modified` with real values.
- If you are blocked, use the `ask` command from the preamble; never open a local question prompt.
````

If the Worker needs more than the Issue says, add a short note below the body in the Task; never rewrite the body.

## Mapping comment

Posted once per Dispatch, right after `worker-start` succeeds. Human-readable lines first, the machine-readable block last:

```
> *Posted by an AI orchestrator.*

Dispatched to an Orca worker.
- Worktree: `issue-123-<slug>` (branch `<branch>`, base `<base>`)
- Run `<run_id>` / Task `<task_id>` / Dispatch `<dispatch_id>`

<!-- orca-issue-orchestrator {"v":1,"repo":"<owner>/<repo>","issue":123,"run_id":"…","task_id":"…","dispatch_id":"…","worktree_id":"…","branch":"…","hub":"<hub_id>"} -->
```

| Field | Source |
|-------|--------|
| `v` | Format version, `1` |
| `repo`, `issue` | The arguments |
| `run_id`, `task_id`, `dispatch_id` | The `worker-start` receipt |
| `worktree_id` | The worktree's `identity.key` from `orca worktree list --json` (e.g. `wt2:local:<uuid>`); select it with `--worktree identity:<key>`. Never the `<repo-id>::<path>` id, which holds a local path |
| `branch` | The worktree's branch, without `refs/heads/` |
| `hub` | `hub_id` from `hub.json`, never a path |

The marker `orca-issue-orchestrator` is how recovery and the concurrency count find in-flight Issues. After a retry there may be several blocks on one Issue; the latest is current.

## Closeout

<!-- Filled by the issue-closeout ticket: success (PR open) and failure comments, assignee / needs-info on failure, worker-release, worktree kept, no automatic retry. -->

*To be written with `scripts/issue-closeout.sh`.*

## Recovery after an Orca restart

<!-- Filled by the issue-closeout and recovery ticket: list open Issues assigned to @me with the marker, read the latest block, run-use the Run, reconcile with worker-list --run and worktree list (linkedIssue). -->

*To be written with the recovery procedure.*

## Reading Orca JSON

- Every `--json` response is `{ok, result, ...}`; read `.result`.
- `orca orchestration check --json` returns `result.messages[]` whose `.payload` is a JSON string; parse it with `fromjson` (`.result.messages[] | .payload | fromjson`).
- A `worker-start` receipt exits 1 unless the Worker is ready; it still carries `failedStage`, `effects[]`, and `residualResources[]`.

## Tests

```sh
skills/orca-issue-orchestrator/tests/dispatch.test.sh
npx --yes shellcheck skills/orca-issue-orchestrator/scripts/*.sh skills/orca-issue-orchestrator/tests/*.sh \
  skills/orca-issue-orchestrator/tests/bin/gh skills/orca-issue-orchestrator/tests/bin/orca
```

The tests put fake `gh` and `orca` (`tests/bin/`) first on `PATH`. They answer from recorded JSON in `tests/fixtures/` and log every call, and the tests assert on the printed plan, the exit code, and the call log (claim before `task-create`; `worker-start`, `worktree set`, and `task-update` never invoked; no mutation in dry-run; the Mapping block complete and free of paths).
