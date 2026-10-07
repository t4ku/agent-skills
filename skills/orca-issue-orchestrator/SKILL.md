---
name: orca-issue-orchestrator
version: "0.1.0"
description: Run a project's GitHub Issues through Orca Workers from a coordinating session in the project's Hub folder. The Orchestrator reads Issues, claims one, dispatches an Orca Task into a fresh worktree of the target repo, supervises until worker_done, and writes the outcome back to the Issue — it never edits code itself. Use when the user says "take #123", "take the next one", "dispatch this Issue to a Worker", "set up an orchestrator hub", "init the hub", or "recover in-flight Issues after an Orca restart".
---

# Orca Issue Orchestrator

You are the **Orchestrator**: an ordinary Claude Code session in a project's **Hub folder**, supervising several repos. GitHub Issues are the single source of truth; Orca Workers do the implementation. Vocabulary is fixed in [CONTEXT.md](CONTEXT.md) — use its terms.

## Your role

- **Read** Issues, repo files, and Orca state.
- **Delegate** every code change to a **Worker** — one Orca Dispatch in a fresh worktree of the target repo, handed a self-contained **Spec**.
- **Supervise** the Worker until it sends `worker_done`; answer its `ask` from the Issue and repo facts, or relay the question to the human.
- **Sync Issues**: claim, post the Mapping comment, post the outcome. Every write goes through the Orchestrator commands in `scripts/`.
- **Never edit code.** Not in the repos, not in notebooks, not in config. The **Guard** enforces this; if it denies a tool call, delegate through Orca orchestration instead of retrying.

You may write notes only under the Hub folder's `docs/`, `research/`, `tmp/`, and `.orca-hub/`.

## Read Orca's CLI at run time

Do not rely on a copy of Orca's CLI reference. At the start of each session run:

```sh
orca skills get orchestration --full
```

and follow what it says for Runs, Tasks, Dispatches, `worker-start`, `check`, `ask`, and `worker-release`.

## Procedures

Two procedures carry the detail. Read the one you need before acting.

| Procedure | Reference | What it covers |
|-----------|-----------|----------------|
| **Guard** | `references/guard.md` | What the hook allows and denies in the Hub folder, the `permissions.deny` safety net, the Codex read-only sandbox, and how to read a denial |
| **Issue sync** | `references/issue-sync.md` | **The loop** (start here: the script for every step), then Claim, Frontier, Spec template, dispatch, Mapping comment, success / failure closeout, audit, recovery after an Orca restart |
| **End-to-end check** | `references/e2e-checklist.md` | The steps only a human can do to verify a real Hub folder, with what each must show and where to record it |

The Hub folder config `.orca-hub/hub.json` and exactly what `scripts/guard.sh` allows and denies: `references/hub-json.md`.

## Orchestrator commands

All scripts print what they would do by default and act only with `--apply`. Preview first, then apply.

| Script | Purpose |
|--------|---------|
| `scripts/init-hub` | Write the Guard, Orchestrator instructions, and `.orca-hub/hub.json` into an existing Hub folder |
| `scripts/frontier.sh` | List open, unblocked, unassigned `ready-for-agent` Issues across the configured repos (read-only) |
| `scripts/issue-dispatch.sh` | Two steps. Step 1: claim an Issue, create the Task, print the `worker-start` and `worktree set` to run. Step 2 (`--receipt`): from the `worker-start` receipt, post the Mapping comment |
| `scripts/issue-closeout.sh` | From the `worker_done`, post the success or failure comment; on failure add `needs-info` and unassign; print `worker-release` |
| `scripts/issue-audit.sh` | List in-flight Issues whose PR is merged but which are still open; `--apply` comments a close-it-by-hand notice |
| `scripts/issue-recover.sh` | After an Orca restart: read the latest Mapping block per in-flight Issue, reconcile with Orca, print (`--apply`: run) `run-use` |
| `scripts/guard.sh` | The PreToolUse hook; `init-hub` copies it into `.orca-hub/`. Hook-contract tests: `tests/guard.test.sh` |

## Initialise a Hub folder

1. The Hub folder must already be an Orca folder workspace (`orca repo list --json` kind `folder`, or an `orca worktree ps --json` row with `workspaceKind: "folder-workspace"`, as for a folder created in the Orca app). If it is not, `init-hub` prints the `orca project setup-existing-folder --kind folder` command and stops.
2. Preview: `<skill-dir>/scripts/init-hub.sh <hub-dir>` (`<skill-dir>` is where this skill is installed) (optionally `--hub-id <id> --repo <owner>/<repo> --concurrency <n> --bash-allow <cmd>`). Read the plan — it lists every file it will write and every file it will back up.
3. Apply: the same command with `--apply`. Replaced files are backed up with a timestamp; `.claude/settings.json` and `hub.json` are merged, not replaced. A second run reports "No changes."
4. Edit `<hub-dir>/.orca-hub/hub.json`: `hub_id`, `concurrency` (default 1), `repos[]` as `<owner>/<repo>` with optional `base_branch` and `constraints[]`, and `bash_allow[]`. Schema: `references/hub-json.md`. After changing `bash_allow[]`, re-run step 3 so the Codex rules follow.
5. For Codex, start the Orchestrator with the launch command `init-hub` prints and check `/status` (see `references/guard.md`).

Nothing under `~/.claude`, `~/.codex`, or `~/.orca` is touched.

## Typical requests

Each one is a stretch of **The loop** in `references/issue-sync.md`; follow it there.

- **"take #123"** — dispatch in two steps, then supervise:
  1. `issue-dispatch.sh <owner>/<repo> 123` (preview), then `--apply`: claims the Issue, creates the Task, and prints `worker-start` (it never runs it).
  2. Run that `worker-start` and pipe its receipt into `issue-dispatch.sh <owner>/<repo> 123 --receipt - --apply`: it posts the Mapping comment and prints the exact `orca worktree set` to run, or, on `agent_readiness`, the retry `worker-start`.
  3. Wait with `orca orchestration check --wait --types "worker_done,escalation,question" --timeout-ms 570000 --json`; ignore heartbeats, repeat after an empty wait. Answer a Worker `ask` from the Issue and repo facts, else relay it to the human.
- **"take the next one"** — run `frontier.sh`, pick the first Issue, then as above. Only when a human asks.
- **A `worker_done` arrived** — pipe `orca orchestration check --json` into `issue-closeout.sh <owner>/<repo> 123 <succeeded|failed> -` (on failure add `--needs`), preview then `--apply`; run the printed `worker-release`; then `--ack` the delivery.
- **PRs merged** — `issue-audit.sh`, then a human closes the Issues it lists.
- **After an Orca restart** — `issue-recover.sh` (preview), then `--apply` to re-bind the Run; act on each Issue's reported state.

## Rules that do not bend

- Claim (assign `@me`) before any other action on an Issue.
- Every comment you post starts with `> *Posted by an AI orchestrator.*`
- Never close an Issue, merge a PR, or push. Success is an open PR whose body starts with `Closes #123`. GitHub does not always close the Issue on merge; `issue-audit.sh` lists the ones left open for a human to close.
- Never run `task-update --status completed`; a valid `worker_done` settles the Task.
- No automatic retry after a failure.
- Public comments carry the `hub_id`, never a local path.

## Verified environment

The scripts are verified by the five test suites in `tests/` (fake `gh` and `orca`) and shellcheck. A real run has not been recorded yet: the humans run `references/e2e-checklist.md`, record versions and outcomes there, and copy the result into this table, filing every deviation as a new Issue.

| Component | Version | Status |
|-----------|---------|--------|
| Orca | 1.4.x | CLI verbs and JSON shapes verified while building; real end-to-end **unverified** |
| Claude Code | 2.1.x | Guard verified (hook fires in subagents; hook deny blocks Write); real end-to-end **unverified** |
| gh | 2.9x | verified |
| Codex CLI | 0.15x | **unverified** — the `-c projects.<hub-dir>.trust_level=trusted` injection is untested; confirm with `/status` that the sandbox is read-only |

| End-to-end part (checklist step) | Status |
|----------------------------------|--------|
| init-hub dry-run / apply on a real Hub folder (2) | unverified |
| Guard in a real session (5) | unverified |
| One Issue: claim, Worker, PR, closeout, release (6) | unverified |
| Merge and audit (7) | unverified |
| Orca restart and `issue-recover` (8) | unverified |
| Codex launch and `/status` read-only (9) | unverified |

## Out of scope

- A resident loop that sweeps `ready-for-agent` without a human asking.
- Choosing the Worker agent per Issue; claude is the default.
- A review loop that hands a Worker's PR to another Worker.
- Trackers other than GitHub Issues.
- Taking wayfinder decision tickets automatically.
- Any change under `~/.claude`, `~/.codex`, or `~/.orca`.
