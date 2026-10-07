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
  "bash_allow": ["make"],
  "orca_worktree_id": "folder:<uuid>",
  "orca_display_name": "example-hub"
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
| `bash_allow[]` | array of strings | no | Extra command names the Guard allows as the first word of a Bash segment, on top of the default allowlist. Matched as exact strings. |
| `orca_worktree_id` | string | no | Orca's worktree id of the Hub folder (`folder:<uuid>`), so later scripts can address it as `id:folder:<uuid>`. Written by `init-hub` when it finds the Hub folder in `orca worktree ps --json` (a row with `workspaceKind: "folder-workspace"`, as for a folder created in the Orca app); left as it is when no such row exists (the folder is known to `orca repo list --json` only). |
| `orca_display_name` | string | no | The Hub folder's `displayName` in that same `orca worktree ps --json` row. |

## How the Guard uses it

`scripts/guard.sh` reads `$CLAUDE_PROJECT_DIR/.orca-hub/hub.json`. If the file is missing, cannot be parsed, or its `hub_path` is not exactly `$CLAUDE_PROJECT_DIR`, the Guard prints nothing and exits 0 — Worker worktrees and every other session are never judged. If the file exists but `jq` is not installed, the Guard cannot tell and denies (fail closed). In the Hub folder it applies these rules:

- **Edit / Write / NotebookEdit** — allowed only when the realpath of `file_path` (`notebook_path` for NotebookEdit) is inside `<hub-dir>/docs/`, `research/`, `tmp/`, or `.orca-hub/`. Relative paths resolve against the Hub folder. Symlinks are followed; a `..` inside a not-yet-existing part of the path is denied.
- **Bash** — the command is split on `&&`, `||`, `;`, `|`, any other unquoted `&`, and newlines (separators inside `'...'`, `"..."`, and `$'...'` do not count). The first word of every segment, read with shell quoting (`'...'`, `"..."`, backslash escapes) and with its quotes removed, must be on the allowlist: `orca`, `gh`, `git` (subcommands `status`, `log`, `diff`, `show`, `branch`, `worktree`, `remote`, `rev-parse`, `ls-files`, `fetch` only), `ls`, `cat`, `rg`, `grep`, `jq`, `head`, `tail`, `wc`, `find`, `echo`, `cd`, `pwd`, `test`, `[`, `true`, the skill's own scripts by basename (`issue-*.sh`, `frontier.sh`), and `bash_allow[]`. A first word that would need expansion (`$` or a backtick outside single quotes, including `$VAR`, `$(...)` and `$'...'`; an unquoted `{`, `*`, `?`, `[` or `(`, except `[` as the whole word), or that does not parse (an unterminated quote, a trailing backslash), is denied; nothing is ever evaluated. A segment containing `>` anywhere, quoted or not, is denied — write files with the Write tool. A `#` that starts an unquoted word begins a comment up to the newline. Subshells (`$(...)`, backticks) are denied as the first word and not parsed anywhere else; `permissions.deny` is the second layer for destructive commands.
- **Everything else** (Agent, Read, Grep, ...) is left alone. Subagent calls, which carry `agent_id` and `agent_type`, get the same rules.

Known gaps of the first version (the allowlist is a guard rail against accidental edits, not a sandbox):

- Scripts are matched by basename only, so any `issue-*.sh` runs, including one written under `tmp/`.
- Some allowlisted commands can still write or execute through their options, e.g. `git diff --output=<file>`, `find -exec`, `rg --pre`.
- Command substitution and subshells are not inspected.

A denial is exit 0 with this stdout (one line):

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Editing code is forbidden in the orchestrator. Create a Task with orca orchestration and delegate it (see /orca-issue-orchestrator)."}}
```

Bash denials append ` Blocked segment: <token>` to the reason, where `<token>` is the first word of the blocked segment (unquoted, or as written when it needs expansion or does not parse), `git <subcommand>` for a git subcommand outside the list, or `>` for a redirect. Malformed hook input in the Hub folder is denied.

## Tests

```sh
skills/orca-issue-orchestrator/tests/guard.test.sh
npx --yes shellcheck skills/orca-issue-orchestrator/scripts/*.sh skills/orca-issue-orchestrator/tests/*.sh
```
