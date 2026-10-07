# End-to-end checklist

The steps only a human can do, in order, to verify the skill on a real machine: a real Hub folder in Orca, a real Orchestrator session, one real Issue taken end to end, an Orca restart, and Codex. The agent's procedure is [issue-sync.md](issue-sync.md) (start at "The loop"); this list drives it and records what happened.

How to use it:

- Work on a copy of this file outside the repo, or in the Hub folder's `docs/`. Tick each box and fill each **Record** line.
- Replace the placeholders: `<hub-dir>` (the Hub folder, an absolute path), `<owner>/<repo>` (a repo of the project, with an Orca repo for it), `123` (a small `ready-for-agent` Issue you are happy to have implemented), `<hub_id>` (the short Hub id that public comments carry, no path), `<project-id>`, `<skill-dir>` (where the skill is installed, e.g. a checkout's `skills/orca-issue-orchestrator`).
- When a step does not give the observable result it names, stop, record what you saw, and file a new Issue for the deviation. Do not fix it in the same run.
- At the end, copy the versions and the outcome of each part into the "Verified environment" table of [SKILL.md](../SKILL.md) through a PR, and link the deviation Issues there.

## 0. Versions

- [ ] Run each and record the output:

  ```sh
  orca --version
  claude --version
  codex --version
  gh --version
  ```

  **Record:** Orca ____ / Claude Code ____ / Codex CLI ____ / gh ____ / OS ____

## 1. Register the Hub folder in Orca

- [ ] Create the folder and register it as an Orca **folder** workspace, either in the Orca desktop app (add an existing folder to the project) or:

  ```sh
  mkdir -p <hub-dir>
  orca project list
  orca project setup-existing-folder --project <project-id> --host local --path <hub-dir> --kind folder
  ```

  **Proves it:** the Hub folder appears under the project in Orca's sidebar, and `orca worktree list --json` has a row whose path is `<hub-dir>`.

  **Record:** UI or CLI: ____ / result: ____

## 2. Initialise the Hub folder

- [ ] Preview:

  ```sh
  <skill-dir>/scripts/init-hub.sh <hub-dir> --hub-id <hub_id> --repo <owner>/<repo>
  ```

  **Proves it:** a plan with the line `Dry-run: nothing written. Re-run with --apply to write <n> change(s).` that lists `CLAUDE.md`, `AGENTS.md`, `.claude/settings.json`, `.claude/agents/orchestrator.md`, `.codex/config.toml`, `.codex/rules/orchestrator.rules`, `.orca-hub/hub.json`, `.orca-hub/guard.sh`, and `docs/`, `research/`, `tmp/`; nothing in `<hub-dir>` changed.

- [ ] Apply: the same command with `--apply`, then run it once more with `--apply`.

  **Proves it:** the first run prints `Wrote <n> change(s).`; the second prints `No changes.` (both followed by the hub.json and Codex next steps) Nothing under `~/.claude`, `~/.codex`, or `~/.orca` changed (compare their modification times before and after).

  **Record:** changes written ____ / second run ____ / Codex launch command printed (yes/no, dot variant or not) ____

## 3. Fill hub.json

- [ ] Edit `<hub-dir>/.orca-hub/hub.json`: `hub_id` (short, no path), `repos[]` (`{"name": "<owner>/<repo>"}`, optional `base_branch`, `constraints[]`), `concurrency` (keep `1` for this run). Schema: [hub-json.md](hub-json.md). If you changed `bash_allow[]`, re-run step 2 with `--apply`.

  **Proves it:** `<skill-dir>/scripts/frontier.sh --hub <hub-dir>` lists Issue 123 among the Frontier lines (tab-separated `<owner>/<repo>#123`, title, URL).

  **Record:** hub_id ____ / repos ____ / concurrency ____

## 4. Start the Orchestrator

- [ ] In Orca, open a terminal in the Hub folder workspace and start plain `claude`. Ask it to read the skill (`/orca-issue-orchestrator`) and run `orca skills get orchestration --full`.

  **Proves it:** the session starts in `<hub-dir>` (it reports `<hub-dir>` as its working directory) and the skill loads.

- [ ] Optional: in a second terminal, `claude --agent orchestrator`.

  **Proves it:** the session has no Edit, Write, or NotebookEdit tool (ask it to list its tools).

  **Record:** plain claude ____ / `--agent orchestrator` ____

## 5. Prove the Guard (Claude Code)

Ask the Orchestrator session to do each of these and watch the result.

- [ ] Create `<hub-dir>/notes.md` (the Hub folder root, outside the four directories).

  **Proves it:** denied with exactly `Editing code is forbidden in the orchestrator. Create a Task with orca orchestration and delegate it (see /orca-issue-orchestrator).`; the file does not exist.

- [ ] Create `<hub-dir>/tmp/scratch.md`.

  **Proves it:** allowed; the file exists.

- [ ] Run `gh issue list -R <owner>/<repo> --limit 5`.

  **Proves it:** it runs and lists Issues.

- [ ] Run `rm -rf <hub-dir>/tmp/scratch.md`.

  **Proves it:** denied (by the hook, `Blocked segment: rm`, or by the `Bash(rm -rf *)` rule); the file still exists.

- [ ] Run `echo x > <hub-dir>/tmp/x.txt`.

  **Proves it:** denied because the segment contains `>`.

  **Record:** each of the five: ____

## 6. One Issue end to end

Ask the Orchestrator to "take #123" and let it follow "The loop" in [issue-sync.md](issue-sync.md). Approve each `--apply` after reading its preview.

- [ ] **Run bound.** If no Run is bound, dispatch step 1 refuses and prints `orca orchestration run-create`; the Orchestrator runs it.

  **Record:** run id ____

- [ ] **Claim and Task** (`issue-dispatch.sh <owner>/<repo> 123`, then `--apply`).

  **Proves it:** Issue 123 is assigned to you on GitHub; the output prints a `worker-start ... --timeout-ms 300000 --json` and an `orca worktree set` line.

- [ ] **Worker started, Mapping comment posted** (the printed `worker-start` piped into `issue-dispatch.sh <owner>/<repo> 123 --receipt - --apply`, then the printed `orca worktree set`).

  **Proves it:** a new worktree `issue-123-<slug>` appears in Orca, linked to Issue 123 in the sidebar; the Issue has one comment that starts with `> *Posted by an AI orchestrator.*`, names the worktree, branch, Run, Task, and Dispatch, ends with an `<!-- orca-issue-orchestrator {...} -->` block carrying `"hub":"<hub_id>"`, and contains no local path.

  **Record:** worktree ____ / did `worker-start` fail at `agent_readiness`, and did the printed retry work? ____

- [ ] **Wait and ask.** The Orchestrator waits with `orca orchestration check --wait --types "worker_done,escalation,question" --timeout-ms 570000 --json` and repeats it after an empty wait. If the Worker asks a question, note whether the Orchestrator answered from the Issue or relayed it to you.

  **Record:** number of waits ____ / questions and how they were answered ____

- [ ] **PR open.** The Worker opens a PR.

  **Proves it:** the PR's body starts with `Closes #123`, its base is the default branch, and its head is the worktree's branch.

  **Record:** PR ____

- [ ] **Closeout** (`orca orchestration check --json | issue-closeout.sh <owner>/<repo> 123 succeeded -`, then `--apply`; then the printed `worker-release`; then `check --ack <delivery_id>`).

  **Proves it:** one `## Worker report: succeeded` comment with the PR link, the summary, and the files; labels and assignee unchanged; `worker-release` reports the terminal released (or `external` / `retained`, which is not a failure); the worktree is still there.

  **Record:** closeout ____ / worker-release state ____

## 7. Merge and audit

- [ ] Review and merge the PR yourself.

- [ ] Ask the Orchestrator to run `issue-audit.sh`.

  **Proves it:** if GitHub closed Issue 123, the audit prints no line for it; if 123 is still open, it prints `<owner>/<repo>: PR #<n> merged, Issue #123 still open: close it by hand`, and `--apply` posts that notice once. Close the Issue by hand in that case.

  **Record:** Issue closed by GitHub on merge (yes/no) ____ / audit output ____

## 8. Orca restart and recovery

Do this with an Issue in flight: dispatch a second small Issue (`124`) as in step 6, up to the Mapping comment, then, before its `worker_done`:

- [ ] Quit the Orca app completely and start it again. Start a new `claude` in the Hub folder terminal.

- [ ] Ask the Orchestrator to run `issue-recover.sh`, then `issue-recover.sh --apply`.

  **Proves it:** the preview lists the in-flight Issue with its Run, Task, Dispatch, worktree (`linked`), and a state (`working`, `inspect`, `succeeded`, or `failed`) with a next step; `--apply` runs only `orca orchestration run-use --id <run_id> --json`; `orca orchestration run-current --json` then names that Run; the loop continues from the reported state to closeout.

  **Record:** state reported ____ / run-use ____ / closed out after recovery ____

## 9. Codex

- [ ] In Orca, run the launch command that step 2 printed (`orca terminal create --worktree path:<hub-dir> --command "codex --sandbox read-only -a never -c projects.<hub-dir>.trust_level=trusted"`, or the `CODEX_HOME` variant when `<hub-dir>` contains a dot).

  **Proves it:** a Codex session starts in `<hub-dir>`.

- [ ] In Codex, run `/status`.

  **Proves it:** the sandbox is **read-only** and approvals are `never`; the Hub folder is trusted.

- [ ] Ask Codex to create `<hub-dir>/notes.md`, then to run `gh issue list -R <owner>/<repo> --limit 5`.

  **Proves it:** the edit is refused and the file does not exist; `gh issue list` runs.

  **Record:** `/status` sandbox ____ / approvals ____ / edit refused ____ / gh ran ____

If `/status` does not show a read-only sandbox, stop using Codex as the Orchestrator and file an Issue.

## 10. Results

- [ ] Fill the "Verified environment" table in [SKILL.md](../SKILL.md) with the versions from step 0 and, per part (Guard, dispatch to closeout, audit, recovery, Codex), `verified` or what failed, and open a PR.
- [ ] Every deviation is a new Issue, linked from that PR.

  **Record:** deviation Issues ____
