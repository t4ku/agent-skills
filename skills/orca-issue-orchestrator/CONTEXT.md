# orca-issue-orchestrator — Glossary

Terms used across this skill, its scripts, and the Issues that drive it. Use these words exactly; retired terms are listed at the end.

## Roles

- **Orchestrator** — an ordinary Claude Code session started in the project's Hub folder. It reads, delegates, supervises, and syncs Issues across repos. It never edits code.
- **Hub folder** — an Orca folder workspace that sits beside a project's repos. One per project.
- **Worker** — one Orca Dispatch started by the Orchestrator through `worker-start`, placed in a worktree of the target repo. It edits code, sends `worker_done` exactly once, and never touches Issues.

## Mechanisms

- **Guard** — what stops the Orchestrator from editing code. Claude Code: hooks plus `permissions.deny`. Codex: a read-only sandbox plus execpolicy rules. It fires only for the Orchestrator. Writes are allowed only in the Hub folder's `docs/`, `research/`, `tmp/`, and `.orca-hub/`.
- **Orchestrator instructions** — SKILL.md, a CLAUDE.md in the Hub folder, and an optional `--agent` definition.
- **Spec** — the Task body handed to a Worker: target, change, constraints, ownership, observable acceptance.
- **Orchestrator commands** — the scripts that sync Issues.
- **Mapping comment** — the single Issue comment posted after dispatch, carrying Run / Task / Dispatch / worktree / branch / hub_id. The source for recovery.
- **hub_id** — a short name for a Hub folder, written to Issues instead of a path.

## Tracker terms

Taken verbatim from mattpocock/skills.

- **Claim** — assigning an Issue to oneself.
- **Frontier** — open, unblocked, unclaimed Issues.
- **Map** — the `wayfinder:map` Issue.
- **Triage labels** — `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`.

## Retired terms

Do not use these:

- "hub" on its own — say **Hub folder**.
- "prompt" — say **Spec** (for a Worker) or **Orchestrator instructions**.
- "hooks" as a layer name — say **Guard**.
- "commands" unqualified — say **Orchestrator commands**.
