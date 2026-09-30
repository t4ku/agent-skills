# Guard

What stops the Orchestrator from editing code. `scripts/init-hub.sh` writes every piece of it into the Hub folder; nothing under `~/.claude`, `~/.codex`, or `~/.orca` is read for writing or changed.

| Layer | Claude Code | Codex |
|-------|-------------|-------|
| Hard stop on edits | PreToolUse hook `.orca-hub/guard.sh` | `--sandbox read-only -a never` |
| Command allowlist | the same hook (Bash) | `.codex/rules/orchestrator.rules` (execpolicy) |
| Destructive-command safety net | `permissions.deny` in `.claude/settings.json` | `forbidden` rules in the same `.rules` file |
| Instructions | `CLAUDE.md`, optional `.claude/agents/orchestrator.md` | `AGENTS.md` (same text as `CLAUDE.md`) |

## What the Guard allows and denies (Claude Code)

The hook judges only when `$CLAUDE_PROJECT_DIR` is exactly `hub_path` in `.orca-hub/hub.json`. Worker worktrees and every other session get no output and run unchanged. In the Hub folder:

- **Edit / Write / NotebookEdit** — allowed only inside `<hub-dir>/docs/`, `research/`, `tmp/`, `.orca-hub/` (realpath, symlinks followed). Everything else is denied: the Hub folder root, other subdirectories, the repos.
- **Bash** — every segment of the command (split on `&&`, `||`, `;`, `|`, `&`, newlines) must start with an allowlisted command: `orca`, `gh`, read-only `git` subcommands, `ls`, `cat`, `rg`, `grep`, `jq`, `head`, `tail`, `wc`, `find`, `echo`, `cd`, `pwd`, `test`, `[`, `true`, the skill's `issue-*.sh` / `frontier.sh`, and `bash_allow[]`. A segment containing `>` is denied.
- **Agent, Read, Grep, and every other tool** — left alone. Subagent tool calls fire the same hook and get the same rules.

The exact parsing rules and known gaps: `references/hub-json.md`, "How the Guard uses it".

### Hook registration

`init-hub` merges this entry into `hooks.PreToolUse` of `<hub-dir>/.claude/settings.json` (with jq; existing hooks, denies, and other keys are kept):

```json
{ "matcher": "Bash|Edit|Write|NotebookEdit",
  "hooks": [{ "type": "command", "command": "'<hub-dir>/.orca-hub/guard.sh'" }] }
```

`.orca-hub/guard.sh` is a copy of `scripts/guard.sh`, not a symlink, with an `# installed-by: ... skill version <x>` line under the shebang. To pick up a newer Guard, re-run `init-hub --apply`; the old copy is kept as a backup.

`init-hub` never sets the `agent` key in `settings.json`: an agent body replaces the default system prompt of every session in the Hub folder, including planning sessions run by a human. `.claude/agents/orchestrator.md` (no Edit / Write / NotebookEdit tools) is used only when a human starts `claude --agent orchestrator`.

## The `permissions.deny` safety net

Six rules that hold even if the hook is missing or crashes:

```
Bash(rm -rf *)  Bash(git push *)  Bash(gh issue close *)  Bash(gh issue delete *)  Bash(gh pr merge *)  Bash(gh repo delete *)
```

There is deliberately no bare `Edit`, `Write`, or `NotebookEdit` deny: it would also block the four note directories, and a bare `Agent` deny would disable subagents before any hook runs.

## Codex (unverified)

The Codex path has not been verified on a real machine. After starting it, run `/status` and confirm the sandbox is **read-only**; if it is not, stop and use Claude Code.

- `.codex/config.toml` sets `sandbox_mode = "read-only"` and `approval_policy = "never"`. With `never`, patches are rejected outright and shell writes are refused by the OS sandbox.
- `.codex/rules/orchestrator.rules` holds execpolicy `prefix_rule(...)` entries: `allow` for every command on the Guard's Bash allowlist (read from `scripts/guard.sh`, git by subcommand) plus `bash_allow[]`, and `forbidden` for the six `permissions.deny` commands. `allow` runs outside the sandbox, which is how `orca` and `gh` reach the network. The skill scripts are allowlisted by basename in the Claude Code Guard only.
- There is no `.codex/hooks.json`: Codex writes hook trust under `~/.codex`.
- The project `.codex/` layer applies only to a trusted project, and trust normally lives in `~/.codex/config.toml`. Orca cannot pass Codex flags, so `init-hub` prints a launch command that injects trust on the command line:

  ```sh
  orca terminal create --worktree path:<hub-dir> --command "codex --sandbox read-only -a never -c projects.<hub-dir>.trust_level=trusted"
  ```

  The `-c` key is split on dots, so when `<hub-dir>` contains a dot `init-hub` prints the alternative instead: a dedicated `CODEX_HOME=<hub-dir>/.codex-home` whose `config.toml` trusts `<hub-dir>` (sign in to Codex once under it).

Without `--sandbox read-only` a folder outside git may be writable, and `AGENTS.md` alone enforces nothing.

Known gap: an `allow` rule runs its whole command outside the sandbox, so options of allowlisted commands can still write (`find -delete`, `git branch -D`, `gh api -X DELETE`). The same options pass the Claude Code Guard; see the known gaps in `references/hub-json.md`.

## How to read a denial

A hook denial arrives as the tool result:

```
Editing code is forbidden in the orchestrator. Create a Task with orca orchestration and delegate it (see /orca-issue-orchestrator).
```

Bash denials end with ` Blocked segment: <token>` — the first word of the segment that failed (`git <subcommand>` for git, `>` for a redirect).

- **Do not retry** the same call in another form. The change belongs to a Worker: create a Task and dispatch it (`references/issue-sync.md`).
- A note or scratch file: write it with the Write tool under `docs/`, `research/`, or `tmp/`.
- A read-only command the Orchestrator needs every day: ask the human to add it to `bash_allow[]` in `.orca-hub/hub.json`, then re-run `init-hub --apply` so the Codex rules follow.
- A denial from `permissions.deny` (Claude Code reports the matching rule) or a Codex `forbidden` rule is final: pushing, merging, closing Issues, and deleting are never the Orchestrator's job.
