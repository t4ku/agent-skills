# Hub config: `.orca-hub/hub.json`

The Hub folder's machine-readable config. `init-hub` writes it to `<hub-dir>/.orca-hub/hub.json`; the Guard (`scripts/guard.sh`) and the Orchestrator commands read it. It lives under `.orca-hub/`, one of the four directories the Orchestrator may write to.

## Example

```json
{
  "hub_id": "example",
  "hub_path": "<hub-dir>",
  "concurrency": 1,
  "repos": [
    { "name": "<owner>/<repo>" },
    {
      "name": "<owner>/<other-repo>",
      "base_branch": "develop",
      "constraints": ["Run the full test suite before opening the PR."]
    }
  ],
  "bash_allow": ["make"]
}
```

## Fields

| Field | Type | Required | Meaning |
|-------|------|----------|---------|
| `hub_id` | string | yes | Short name of the Hub folder. Written to Issues (Mapping comment) instead of a path. |
| `hub_path` | string | yes | Absolute path of the Hub folder, exactly as Claude Code reports it in `$CLAUDE_PROJECT_DIR` (no trailing slash). The Guard judges only when the two strings are equal. |
| `concurrency` | integer | no (default `1`) | How many Workers the Orchestrator runs at once. |
| `repos[]` | array of objects | yes | The repos this Hub folder supervises. |
| `repos[].name` | string | yes | `<owner>/<repo>`. Matched against `gitRemoteIdentity.canonicalKey` (`github.com/<owner>/<repo>`) in `orca repo list --json`. |
| `repos[].base_branch` | string | no | Base branch for Worker worktrees. Defaults to the repo's default branch. |
| `repos[].constraints[]` | array of strings | no | Extra constraints pasted into every Spec for this repo. |
| `bash_allow[]` | array of strings | no | Extra command names the Guard allows as the first token of a Bash segment, on top of the default allowlist. Matched as exact strings. |

## How the Guard uses it

`scripts/guard.sh` reads `$CLAUDE_PROJECT_DIR/.orca-hub/hub.json`. If the file is missing, or `hub_path` is not exactly `$CLAUDE_PROJECT_DIR`, the Guard prints nothing and exits 0 — Worker worktrees and every other session are never judged. In the Hub folder it applies these rules:

- **Edit / Write / NotebookEdit** — allowed only when the realpath of `file_path` (`notebook_path` for NotebookEdit) is inside `<hub-dir>/docs/`, `research/`, `tmp/`, or `.orca-hub/`. Relative paths resolve against the Hub folder. Symlinks are followed; a `..` inside a not-yet-existing part of the path is denied.
- **Bash** — the command is split on `&&`, `||`, `;`, `|`, a lone `&`, and newlines (separators inside quotes do not count). The first token of every segment must be on the allowlist: `orca`, `gh`, `git` (subcommands `status`, `log`, `diff`, `show`, `branch`, `worktree`, `remote`, `rev-parse`, `ls-files`, `fetch` only), `ls`, `cat`, `rg`, `grep`, `jq`, `head`, `tail`, `wc`, `find`, `echo`, `cd`, `pwd`, `test`, `[`, `true`, the skill's own scripts by basename (`issue-*`, `frontier`, `frontier.sh`), and `bash_allow[]`. A segment containing `>` anywhere, quoted or not, is denied — write files with the Write tool. Subshells (`$(...)`, backticks) are not parsed; `permissions.deny` is the second layer for destructive commands.
- **Everything else** (Agent, Read, Grep, ...) is left alone. Subagent calls, which carry `agent_id` and `agent_type`, get the same rules.

A denial is exit 0 with this stdout (one line):

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Editing code is forbidden in the orchestrator. Create a Task with orca orchestration and delegate it (see /orca-issue-orchestrator)."}}
```

Bash denials append ` Blocked segment: <token>` to the reason, where `<token>` is the first token of the blocked segment, `git <subcommand>` for a git subcommand outside the list, or `>` for a redirect. Malformed hook input in the Hub folder is denied.

## Tests

```sh
skills/orca-issue-orchestrator/tests/guard.test.sh
npx --yes shellcheck skills/orca-issue-orchestrator/scripts/*.sh skills/orca-issue-orchestrator/tests/*.sh
```
