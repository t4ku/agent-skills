# Issue sync

How the Orchestrator moves a GitHub Issue through an Orca Worker and back: Frontier, Claim, Spec, dispatch, Mapping comment, closeout, recovery. Vocabulary: [CONTEXT.md](../CONTEXT.md). Hub config: [hub-json.md](hub-json.md).

Every write goes through an Orchestrator command. Each one prints what it would do and acts only with `--apply`: preview, read the plan, then apply.

## Rules

- Claim (assign `@me`) before any other write on an Issue.
- Every comment starts with `> *Posted by an AI orchestrator.*`
- Public comments carry the `hub_id`, never a local path.
- Never close an Issue, merge a PR, or push. GitHub may not link `Closes #123` from the PR body (it has happened: `closingIssuesReferences` stayed empty), so never assume the Issue closes on merge; `scripts/issue-audit.sh` finds the leftovers and a human closes them.
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
3. **Concurrency**: the open Issues assigned to `@me` whose comments hold a trusted Mapping block (see [Which blocks are trusted](#which-blocks-are-trusted)), summed over every configured repo, are fewer than `concurrency` (default 1). `--force` dispatches anyway. If the count cannot be read (gh fails, or the authenticated login is unknown), it refuses. An Issue between step 1 and step 2 has no Mapping block yet and is not counted, so finish step 2 before dispatching the next Issue.
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

The marker `orca-issue-orchestrator` is how recovery and the concurrency count find in-flight Issues. After a retry there may be several blocks on one Issue; the latest trusted one is current.

### Which blocks are trusted

Anyone can comment on a public Issue, so a copied or forged block must not make closeout consume another Dispatch or recovery rebind to another Run. Closeout, audit, recovery, and the concurrency count in dispatch read only blocks that pass every check:

- The comment's author is the login gh is authenticated as (`gh api user --jq .login`, looked up once per run). If it cannot be read, the script refuses.
- `v` is `1`.
- `repo` is the Issue's `<owner>/<repo>` and `issue` is its number.
- `hub` is the `hub_id` in `hub.json` (without a loaded `hub.json`, any non-empty `hub` is accepted and its value is logged).

Every other block is skipped with a `warning: <owner>/<repo>#123: ignoring a Mapping block: <reason>` line on stderr. An Issue with no trusted block is not in flight. The closeout and audit markers (and the Mapping-comment dedupe in step 2 of dispatch) likewise count only when the authenticated login posted them, so a forged marker cannot suppress a real comment.

## Closeout

When a `worker_done` for the Dispatch in an Issue's latest Mapping block arrives, write the outcome back with `scripts/issue-closeout.sh`. Feed it the `check --json` batch that holds the `worker_done` (or a plain-text summary you wrote):

```sh
orca orchestration check --json | scripts/issue-closeout.sh <owner>/<repo> 123 succeeded -            # preview
orca orchestration check --json | scripts/issue-closeout.sh <owner>/<repo> 123 succeeded - --apply    # act
orca orchestration check --json | scripts/issue-closeout.sh <owner>/<repo> 123 failed - \
  --needs "<what a human must supply>" --apply
```

`check` replays the same batch until you `--ack` it, so preview and apply see the same messages; acknowledge only after the closeout. The Guard denies `>`, so to keep a batch use the Write tool under `tmp/` and pass the file instead of `-`.

From a batch it takes the last message with `type == "worker_done"` whose `.payload | fromjson` has the `dispatchId` of the Issue's latest Mapping block; heartbeats and other Dispatches in the same batch are ignored. The summary is the message `.body`; `filesModified[]` and `reportPath` come from the payload. If the payload's `outcome` differs from the argument, or the batch has no `worker_done` for that Dispatch, it refuses. With a plain-text file, pass `--files a,b` for the files modified (`--files` also overrides the payload). `-` reads stdin.

**Success** (`succeeded`, the PR is open, at least one file modified): one comment, nothing else. Labels and assignee stay as they are; the assignee keeps the Issue out of the Frontier until the PR merges.

```
> *Posted by an AI orchestrator.*

## Worker report: succeeded

Pull request: https://github.com/<owner>/<repo>/pull/456

<the three-sentence summary>

**Files modified:**
- `<file>`

Worktree `issue-123-<slug>` (branch `<branch>`) is kept for review.

<!-- orca-issue-orchestrator-closeout {"v":1,"dispatch_id":"…","outcome":"succeeded"} -->
```

The PR is `--pr <url|number>`, else the first `https://github.com/<owner>/<repo>/pull/<n>` in the summary, else the open PR whose head is the Mapping block's branch. Whatever the source, it then runs `gh pr view <n> -R <owner>/<repo> --json number,state,headRefName,headRepository,headRepositoryOwner,isCrossRepository,url` and refuses the succeeded closeout, naming the mismatch, unless the PR is:

- `OPEN` (not merged, not closed),
- in `<owner>/<repo>` (a URL of another repo is refused before the lookup),
- from a head in `<owner>/<repo>` itself (`isCrossRepository` false; a fork's branch of the same name does not count),
- on the head branch named by the Mapping block's `branch`.

No open PR means no success: it refuses.

The files section is always rendered. A succeeded closeout with no files (an empty `filesModified[]`, or a plain-text summary without `--files`) refuses, even in dry-run; pass `--files a,b`.

**Failure** (`failed`, or Orca reports a failed attempt): with `--apply`, in this order:

1. `gh issue edit 123 -R <owner>/<repo> --add-label needs-info --remove-label ready-for-agent` (`--remove-label` only when the Issue has it; label first, so a failed unassign cannot put the Issue back in the Frontier)
2. `gh issue edit 123 -R <owner>/<repo> --remove-assignee @me`
3. `gh issue comment 123 -R <owner>/<repo> --body-file -` with the failed report:

```
> *Posted by an AI orchestrator.*

## Worker report: failed

**What was attempted:** <the summary>

**Evidence:** <--evidence, else where Orca keeps the Worker's output (worker-read --dispatch)>

**What is needed from a human:** <--needs, required with --apply>

Worktree `issue-123-<slug>` (branch `<branch>`) is kept for inspection.

<!-- orca-issue-orchestrator-closeout {"v":1,"dispatch_id":"…","outcome":"failed"} -->
```

Pass `--evidence` with the gist of the report file, or the tail of `orca orchestration worker-read --dispatch <dispatch_id> --limit 50 --json`, rewritten without local paths; the default only points at `worker-read`. Write `--needs` yourself from the report: the information missing from the Issue, or the decision a human must take. `reportPath` is a local path and is never posted. There is no automatic retry; the Issue returns to the Frontier when a human answers and restores `ready-for-agent`.

Both paths:

- Print, never run, `orca orchestration worker-release --dispatch <dispatch_id> --json`. Run it after the comment is posted. It exits 0 even when the resource stays `external` / `retained` (a terminal created by an earlier failed attempt); read the state it reports, it is not a failure. The worktree is kept.
- Never run `gh issue close` or `task-update`.
- Refuse to post a body holding the Hub folder path, your home directory, or a `::/` worktree path.
- Post once per Dispatch: if a closeout block for the same `dispatch_id` is already on the Issue, change nothing and only print `worker-release` (also after the PR merged).

### Merged PR, Issue still open

GitHub has not linked `Closes #123` on every PR (`closingIssuesReferences` stayed empty and the Issue stayed open after the merge). Check after merges:

```sh
scripts/issue-audit.sh            # preview
scripts/issue-audit.sh --apply    # also comment the notice on the Issue
```

For every in-flight Issue (open, assigned to `@me`, with a Mapping block) it finds the PRs of the same repo whose body says `Closes` / `Fixes` / `Resolves #123`, and for each merged one prints:

```
<owner>/<repo>: PR #456 merged, Issue #123 still open: close it by hand
```

With `--apply` it posts that notice on the Issue, once per PR (marker `<!-- orca-issue-orchestrator-audit {"v":1,"pr":456} -->`). It never closes the Issue; a human does.

## Recovery after an Orca restart

The Issues are the source of truth; Orca state is consulted afterwards.

```sh
scripts/issue-recover.sh            # preview
scripts/issue-recover.sh --json     # the same as {issues, runs, bound_run, run_use}
scripts/issue-recover.sh --apply    # also re-bind the Run
```

1. For every repo in `hub.json`: `gh issue list --assignee @me --state open --search "orca-issue-orchestrator in:comments"`, keeping Issues with a trusted Mapping block (see [Which blocks are trusted](#which-blocks-are-trusted)).
2. Read the **latest** trusted block on each Issue (after a retry there are several).
3. Reconcile: `orca orchestration worker-list --run <run_id> --json` (all pages) for the row of the block's `dispatchId`, and `orca worktree list --json` for the row whose `identity.key` is the block's `worktree_id` and its `linkedIssue`.
4. Print `orca orchestration run-use --id <run_id> --json`. `--apply` runs it, and nothing else; it prints but skips it when the terminal is already bound to that Run and refuses when the Issues name more than one Run (bind the one you want by hand).

Per Issue it reports the Issue, Run, Task, Dispatch, worktree (`linked`, `unlinked`, or `missing`), the worker row, and a state with its next step:

| State | Meaning | Next |
|-------|---------|------|
| `closed-out` | a closeout comment for the Dispatch is on the Issue | wait for the merge; `issue-audit.sh` |
| `succeeded` | `worker_done` succeeded | `issue-closeout.sh … succeeded` with the `worker_done` |
| `failed` | `worker_done` failed | `issue-closeout.sh … failed … --needs` |
| `working` | no outcome yet, agent `live` | `check --wait` |
| `inspect` | no outcome, agent not proven live | `worker-show --dispatch`; never stop or retry from absence |
| `unknown` | the Run has no worker row for the Dispatch | `worker-show --dispatch` |

An `unlinked` worktree also gets `orca worktree set --worktree identity:<key> --issue 123 --json` to run yourself. A Task whose newest Dispatch has no Mapping comment is flagged.

## Reading Orca JSON

- Every `--json` response is `{ok, result, ...}`; read `.result`.
- `orca orchestration check --json` returns `result.messages[]` whose `.payload` is a JSON string; parse it with `fromjson` (`.result.messages[] | .payload | fromjson`). Heartbeats arrive in the same batch. A `worker_done` payload has `taskId`, `dispatchId`, `outcome` (`succeeded` / `failed`), `filesModified[]`, and an optional `reportPath`; the human summary is the message `.body`.
- `orca orchestration worker-list --run <run_id> --json` is the fleet view: `result.workers[]` with `dispatchId`, `taskId`, `workerState`, `terminalState`, `resource.ownershipState`, `projection.outcome`, `projection.liveness.verdict`; `result.page.nextCursor` while `hasMore`.
- `orca worktree list --json` rows carry `identity.key` and `linkedIssue` (an integer).
- A `worker-start` receipt exits 1 unless the Worker is ready; it still carries `failedStage`, `effects[]`, and `residualResources[]`.

## Tests

```sh
skills/orca-issue-orchestrator/tests/dispatch.test.sh
skills/orca-issue-orchestrator/tests/closeout.test.sh
skills/orca-issue-orchestrator/tests/recover.test.sh
npx --yes shellcheck skills/orca-issue-orchestrator/scripts/*.sh skills/orca-issue-orchestrator/tests/*.sh \
  skills/orca-issue-orchestrator/tests/bin/gh skills/orca-issue-orchestrator/tests/bin/orca
```

The tests put fake `gh` and `orca` (`tests/bin/`) first on `PATH`. They answer from recorded JSON in `tests/fixtures/` and log every call, and the tests assert on the printed plan, the exit code, and the call log (claim before `task-create`; `worker-start`, `worktree set`, and `task-update` never invoked; no mutation in dry-run; the Mapping block complete and free of paths; on closeout success one comment and no label or assignee change, on failure the label add, the unassign, and the comment in that order; `gh issue close` and `task-update` never invoked; recovery uses the latest of two Mapping blocks and runs only `run-use`; forged Mapping blocks from another author, or with a wrong repo, issue, hub, or version, are ignored by closeout, audit, recovery, and the concurrency count; a `--pr` that is merged, from another repo or a fork, or on another head branch refuses; a succeeded closeout without files refuses). The fake `gh` answers `gh api user` from `user.json` and `gh pr view <n>` from `pr-<owner>_<repo>-<n>.json`. `tests/helpers.sh` holds the shared setup.
