#!/usr/bin/env bash
# orca-issue-orchestrator init-hub: write the Guard, the Orchestrator
# instructions, and .orca-hub/hub.json into an existing Hub folder.
#
# Usage: init-hub.sh <hub-dir> [--apply] [--hub-id <id>] [--repo <owner>/<repo>]...
#                    [--concurrency <n>] [--bash-allow <command>]...
#
# Dry-run by default: prints the plan (create / update / keep for every file,
# append block / update block for CLAUDE.md and AGENTS.md) and writes nothing.
# With --apply it writes the plan. Every file it changes is first backed up as
# <file>.bak.<timestamp>; .claude/settings.json and .orca-hub/hub.json are
# merged with jq, so existing hooks, denies and hand edits survive. An existing
# CLAUDE.md or AGENTS.md only gains (or has updated) the lines between
# <!-- orca-issue-orchestrator:start --> and <!-- orca-issue-orchestrator:end -->;
# every other byte is kept. A second run with the same arguments reports
# "No changes."
#
# The Hub folder must be an Orca folder workspace (`orca repo list --json`
# reports it with kind "folder", or `orca worktree ps --json` with
# workspaceKind "folder-workspace", as for a folder created in the Orca app);
# otherwise the setup command is printed and the script exits 2. Nothing
# outside the Hub folder is written, in particular nothing under ~/.claude,
# ~/.codex or ~/.orca.
#
# Dependencies: bash (3.2+), jq, coreutils, orca. What the written files do:
# references/guard.md. Tests: tests/init-hub.test.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GUARD_SRC="$SCRIPT_DIR/guard.sh"

HOOK_MATCHER='Bash|Edit|Write|NotebookEdit'
DENY_JSON='["Bash(rm -rf *)","Bash(git push *)","Bash(gh issue close *)","Bash(gh issue delete *)","Bash(gh pr merge *)","Bash(gh repo delete *)"]'
AGENT_TOOLS='Read, Grep, Glob, Bash, Agent, Skill, WebFetch, WebSearch, TodoWrite'
EMPTY_DIRS='docs research tmp'
BLOCK_START='<!-- orca-issue-orchestrator:start -->'
BLOCK_END='<!-- orca-issue-orchestrator:end -->'

usage() {
  sed -n 's/^# \{0,1\}//; 5,6p' "${BASH_SOURCE[0]}"
}

die() {
  printf 'init-hub: %s\n' "$1" >&2
  exit "${2:-1}"
}

# --- arguments ----------------------------------------------------------------

hub_arg=""
apply=0
hub_id=""
concurrency=""
repos=()
bash_allow=()
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1 ;;
    --hub-id|--repo|--concurrency|--bash-allow)
      [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"
      case "$1" in
        --hub-id) hub_id="$2" ;;
        --repo) repos+=("$2") ;;
        --concurrency) concurrency="$2" ;;
        --bash-allow) bash_allow+=("$2") ;;
      esac
      shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option: $1" ;;
    *)
      [ -z "$hub_arg" ] || die "only one <hub-dir> is allowed"
      hub_arg="$1" ;;
  esac
  shift
done
if [ -z "$hub_arg" ]; then
  usage >&2
  exit 1
fi
case "$concurrency" in
  '') ;;
  *[!0-9]*|0*) die "--concurrency must be a positive integer" ;;
esac
for r in ${repos[@]+"${repos[@]}"}; do
  case "$r" in
    */*) ;;
    *) die "--repo must be <owner>/<repo>: $r" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required"

# --- is it an Orca folder workspace? -------------------------------------------

# not_workspace <path> <why>: print how to register the folder, then exit 2.
not_workspace() {
  printf 'init-hub: %s\n\n' "$2" >&2
  printf 'Create the folder and register it with Orca as a folder workspace, then run init-hub again:\n\n' >&2
  [ -d "$1" ] || printf '  mkdir -p %s\n' "$1" >&2
  printf '  orca project setup-existing-folder --project <project-id> --host local --path %s --kind folder\n\n' "$1" >&2
  printf 'or add the folder in the Orca app.\n' >&2
  echo "(Run \`orca project list\` to see the project ids.)" >&2
  exit 2
}

[ -d "$hub_arg" ] || not_workspace "$hub_arg" "$hub_arg does not exist."
hub_real="$(cd "$hub_arg" && pwd -P)" || die "cannot enter $hub_arg"

command -v orca >/dev/null 2>&1 || not_workspace "$hub_real" "the orca CLI is not on PATH, so the folder cannot be confirmed as an Orca folder workspace."

# hub_path is the path Orca holds for the folder: sessions it starts there get
# it as $CLAUDE_PROJECT_DIR, and the Guard judges only on an exact match.
# Two sources know folder workspaces: `orca repo list` (kind "folder") and
# `orca worktree ps` (workspaceKind "folder-workspace"). A Hub folder created
# in the Orca app appears only in the second; its row also carries the worktree
# id and display name recorded in hub.json.

# matching_row <rows of path, worktree id, display name>: print the first row
# whose path resolves to the Hub folder. Fields are separated by \037 so that
# empty ones survive read.
matching_row() {
  local p rest
  while IFS=$'\037' read -r p rest; do
    [ -n "$p" ] || continue
    if [ "$(cd "$p" 2>/dev/null && pwd -P)" = "$hub_real" ]; then
      printf '%s\037%s\n' "${p%/}" "$rest"
      return 0
    fi
  done <<EOF
$1
EOF
  return 1
}

failed_sources=""
list_row=""
ps_row=""
if json="$(orca repo list --json 2>/dev/null)"; then
  list_row="$(matching_row "$(printf '%s' "$json" | jq -r '.result.repos[]? | select(.kind == "folder") | [.path // "", "", ""] | join("\u001f")' 2>/dev/null)")"
else
  failed_sources="orca repo list"
fi
if json="$(orca worktree ps --json 2>/dev/null)"; then
  ps_row="$(matching_row "$(printf '%s' "$json" | jq -r '.result.worktrees[]? | select(.workspaceKind == "folder-workspace") | [.path // "", .worktreeId // "", .displayName // ""] | join("\u001f")' 2>/dev/null)")"
else
  failed_sources="${failed_sources:+$failed_sources and }orca worktree ps"
fi
if [ -z "$list_row$ps_row" ]; then
  [ -z "$failed_sources" ] ||
    not_workspace "$hub_real" "$failed_sources failed (is Orca running?), so the folder cannot be confirmed as an Orca folder workspace."
  not_workspace "$hub_real" "$hub_real is not an Orca folder workspace: neither \`orca repo list --json\` (kind \"folder\") nor \`orca worktree ps --json\` (workspaceKind \"folder-workspace\") reports it."
fi
# The repo list path wins (as before); the Orca ids come from worktree ps only.
IFS=$'\037' read -r hub_path _ _ <<EOF
${list_row:-$ps_row}
EOF
IFS=$'\037' read -r _ orca_worktree_id orca_display_name <<EOF
$ps_row
EOF

# --- staging ----------------------------------------------------------------------

STAGE="$(mktemp -d)" || die "mktemp failed"
trap 'rm -rf "$STAGE"' EXIT

# Every file of the plan: its path relative to the Hub folder, and its action.
plan_paths=()
plan_actions=()

# inside_hub <relative path>: the deepest existing ancestor of the target must
# resolve inside the Hub folder, so a symlinked .claude/ or .codex/ never
# redirects a write elsewhere (for instance into the home directory).
inside_hub() {
  local dir
  dir="$(dirname -- "$hub_real/$1")"
  while [ ! -e "$dir" ]; do dir="$(dirname -- "$dir")"; done
  dir="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
  case "$dir/" in
    "$hub_real"/*) return 0 ;;
  esac
  return 1
}

# stage <relative path>: compare $STAGE/<relative path> with the Hub folder's
# file and record create / update / keep. A symlink or non-file is replaced.
stage() {
  local rel="$1" target="$hub_real/$1" action
  inside_hub "$rel" || die "$rel resolves outside the Hub folder; refusing to write through a symlink"
  if [ -L "$target" ] || { [ -e "$target" ] && [ ! -f "$target" ]; }; then
    action=update
  elif [ ! -e "$target" ]; then
    action=create
  elif ! cmp -s "$STAGE/$rel" "$target"; then
    action=update
  elif [ -x "$STAGE/$rel" ] && [ ! -x "$target" ]; then
    action=update
  else
    action=keep
  fi
  plan_paths+=("$rel")
  plan_actions+=("$action")
}

# staged <relative path>: create the staging directory and print the path.
staged() {
  mkdir -p "$(dirname -- "$STAGE/$1")"
  printf '%s\n' "$STAGE/$1"
}

# existing_json <relative path>: print the Hub folder's JSON file, or nothing
# when it does not exist. Call check_json_object first: a die inside $(...)
# would only leave the subshell.
existing_json() {
  [ ! -f "$hub_real/$1" ] || cat "$hub_real/$1"
}

# check_json_object <relative path>: die unless the file is missing or a JSON object.
check_json_object() {
  [ -f "$hub_real/$1" ] || return 0
  jq -e 'type == "object"' "$hub_real/$1" >/dev/null 2>&1 || die "$1 exists but is not a JSON object; fix or move it first"
}

# json_array <values...>: print the values as a JSON array of strings.
json_array() {
  if [ $# -eq 0 ]; then
    echo '[]'
  else
    printf '%s\n' "$@" | jq -R . | jq -sc .
  fi
}

# CLAUDE.md and AGENTS.md: the Orchestrator block between BLOCK_START and
# BLOCK_END. An existing file keeps every byte outside the markers.
BLOCK="$STAGE/.block.md"
{
  printf '%s\n' "$BLOCK_START"
  cat <<'EOF'
<!-- Written by orca-issue-orchestrator init-hub. A re-run replaces only the lines between these markers. -->
## Orchestrator

This is the Hub folder of the orca-issue-orchestrator skill. As the Orchestrator, follow `/orca-issue-orchestrator`: read Issues, delegate every code change to an Orca Worker, supervise it, and sync the outcome back to the Issue.
Never edit code here or in the repos; the Guard (`.orca-hub/guard.sh`) denies it. Config: `.orca-hub/hub.json`.
Research notes go in `research/`, durable notes in `docs/`, scratch in `tmp/`.
EOF
  printf '%s\n' "$BLOCK_END"
} > "$BLOCK"

# marker_lines <file> <marker>: the line numbers of <marker> (LF or CRLF),
# one per line. Lines inside ``` or ~~~ fences are examples, not markers.
marker_lines() {
  awk -v m="$2" '
    /^[ \t]*(```|~~~)/ { fenced = !fenced; next }
    !fenced { line = $0; sub(/\r$/, "", line); if (line == m) print NR }
  ' "$1"
}

# resolve_file <path>: print the physical path of a regular file, following
# symlinks (readlink without -f, for macOS).
resolve_file() {
  local p="$1" link
  while [ -L "$p" ]; do
    link="$(readlink -- "$p")"
    case "$link" in
      /*) p="$link" ;;
      *) p="$(dirname -- "$p")/$link" ;;
    esac
  done
  printf '%s/%s\n' "$(cd "$(dirname -- "$p")" && pwd -P)" "$(basename -- "$p")"
}

# stage_block <relative path>: stage the file with the block merged in and
# record create / append block / update block / keep. A missing file is
# created (as stage does). A symlink to a file inside the Hub folder is merged
# and written through, so AGENTS.md -> CLAUDE.md stays a link; any other
# symlink stops init-hub. A non-file is replaced (update, as stage does).
stage_block() {
  local rel="$1" target="$hub_real/$1" out src starts ends last_nl last2_nl
  inside_hub "$rel" || die "$rel resolves outside the Hub folder; refusing to write through a symlink"
  out="$(staged "$rel")"
  if [ -L "$target" ]; then
    [ -f "$target" ] || die "$rel is a symlink that does not point to a file; fix or remove it first"
    src="$(resolve_file "$target")"
    case "$src" in
      "$hub_real"/*) ;;
      *) die "$rel is a symlink to a file outside the Hub folder; refusing to write through it" ;;
    esac
  elif [ -f "$target" ]; then
    src="$target"
  else
    { printf '# Hub folder\n\n'; cat "$BLOCK"; } > "$out"
    stage "$rel"
    return
  fi
  starts="$(marker_lines "$src" "$BLOCK_START")"
  ends="$(marker_lines "$src" "$BLOCK_END")"
  plan_paths+=("$rel")
  if [ -z "$starts$ends" ]; then
    # Append after one blank line (none for an empty file): count the
    # newlines in the last byte and in the last two bytes.
    last_nl=$(($(tail -c 1 -- "$src" | wc -l)))
    last2_nl=$(($(tail -c 2 -- "$src" | wc -l)))
    {
      cat -- "$src"
      if [ ! -s "$src" ] || [ "$last2_nl" -eq 2 ]; then
        :
      elif [ "$last_nl" -eq 1 ]; then
        printf '\n'
      else
        printf '\n\n'
      fi
      cat "$BLOCK"
    } > "$out"
    plan_actions+=("append block")
    # The unmarked five-line text an older init-hub wrote.
    ! grep -q -F -e "$LEGACY_LINE" -- "$src" || legacy_files="$legacy_files $rel"
    return
  fi
  # One line number each, start before end; a newline means a repeated marker.
  case "$starts$ends" in
    *[!0-9]*) die "$rel has more than one $BLOCK_START or $BLOCK_END line; fix it by hand" ;;
  esac
  [ -n "$starts" ] && [ -n "$ends" ] && [ "$starts" -lt "$ends" ] ||
    die "$rel has an unmatched $BLOCK_START or $BLOCK_END line; fix it by hand"
  {
    [ "$starts" -le 1 ] || head -n "$((starts - 1))" -- "$src"
    cat "$BLOCK"
    tail -n "+$((ends + 1))" -- "$src"
  } > "$out"
  if cmp -s "$out" "$src"; then
    plan_actions+=(keep)
  else
    plan_actions+=("update block")
  fi
}

LEGACY_LINE='This is the Hub folder of the orca-issue-orchestrator skill.'
legacy_files=""
stage_block CLAUDE.md
stage_block AGENTS.md

# .claude/settings.json: add the Guard hook and the denies; keep everything else.
guard_path="$hub_path/.orca-hub/guard.sh"
hook_cmd="'$(printf '%s' "$guard_path" | sed "s/'/'\\\\''/g")'"
check_json_object .claude/settings.json
settings_old="$(existing_json .claude/settings.json)"
empty_object="{}"
printf "%s" "${settings_old:-$empty_object}" | jq --arg cmd "$hook_cmd" --arg matcher "$HOOK_MATCHER" --argjson deny "$DENY_JSON" '
  {matcher: $matcher, hooks: [{type: "command", command: $cmd}]} as $entry
  | .hooks = (.hooks // {})
  | .hooks.PreToolUse = ((.hooks.PreToolUse // []) as $pre
      | if any($pre[]; . == $entry) then $pre
        else [$pre[]
              | if any(.hooks[]?; .command == $cmd)
                then (.hooks |= map(select(.command != $cmd)) | select(.hooks | length > 0))
                else . end]
             + [$entry]
        end)
  | .permissions = (.permissions // {})
  | .permissions.deny = ((.permissions.deny // []) as $d | $d + [$deny[] | . as $x | select($d | any(. == $x) | not)])
' > "$(staged .claude/settings.json)" || die "could not merge .claude/settings.json"
stage .claude/settings.json

# .claude/agents/orchestrator.md: an optional `claude --agent orchestrator`
# layer with no editing tools. The `agent` settings key is never set.
cat > "$(staged .claude/agents/orchestrator.md)" <<EOF
---
name: orchestrator
description: The Orchestrator of this Hub folder. Reads GitHub Issues, dispatches Orca Workers, supervises them, and syncs the outcome back to the Issue. Never edits code.
tools: $AGENT_TOOLS
---

You are the Orchestrator of this Hub folder. Follow CLAUDE.md and the orca-issue-orchestrator skill (/orca-issue-orchestrator). You have no editing tools: delegate every code change to an Orca Worker.
EOF
stage .claude/agents/orchestrator.md

# .codex/config.toml: read-only sandbox, no approvals.
cat > "$(staged .codex/config.toml)" <<'EOF'
# Written by orca-issue-orchestrator init-hub. The Orchestrator never edits code.
sandbox_mode = "read-only"
approval_policy = "never"
EOF
stage .codex/config.toml

# .orca-hub/hub.json: arguments over the existing file over the template.
default_id="$(basename -- "$hub_path" | tr -c 'A-Za-z0-9._\n-' '-')"
check_json_object .orca-hub/hub.json
hub_old="$(existing_json .orca-hub/hub.json)"
printf '%s' "${hub_old:-null}" | jq \
  --arg hub "$hub_path" --arg default_id "$default_id" --arg id "$hub_id" --arg conc "$concurrency" \
  --arg wt "$orca_worktree_id" --arg wt_name "$orca_display_name" \
  --argjson repos "$(json_array ${repos[@]+"${repos[@]}"})" \
  --argjson allow "$(json_array ${bash_allow[@]+"${bash_allow[@]}"})" '
  (. // {hub_id: $default_id, hub_path: $hub, concurrency: 1, repos: [], bash_allow: []})
  | .hub_path = $hub
  | .hub_id = (if $id != "" then $id else (.hub_id // $default_id) end)
  | if $conc != "" then .concurrency = ($conc | tonumber) else . end
  | if $wt != "" then .orca_worktree_id = $wt else . end
  | if $wt_name != "" then .orca_display_name = $wt_name else . end
  | .repos = ((.repos // []) as $r | $r + [$repos[] | . as $n | select($r | any(.name == $n) | not) | {name: .}])
  | .bash_allow = ((.bash_allow // []) as $b | $b + [$allow[] | . as $x | select($b | any(. == $x) | not)])
' > "$(staged .orca-hub/hub.json)" || die "could not build .orca-hub/hub.json"
stage .orca-hub/hub.json

# .codex/rules/orchestrator.rules: execpolicy allow rules mirroring the Guard's
# Bash allowlist, read from guard.sh, plus bash_allow[] from hub.json.
[ -f "$GUARD_SRC" ] || die "missing $GUARD_SRC"
allowed="$(sed -n "s/^ALLOWED_COMMANDS='\(.*\)'$/\1/p" "$GUARD_SRC")"
allowed_git="$(sed -n "s/^ALLOWED_GIT='\(.*\)'$/\1/p" "$GUARD_SRC")"
[ -n "$allowed" ] && [ -n "$allowed_git" ] || die "cannot read the allowlist from $GUARD_SRC"
# The permissions.deny list is mirrored as forbidden rules; the most
# restrictive matching rule wins, so `gh issue close` stays blocked under `gh`.
jq -r --arg cmds "$allowed" --arg git "$allowed_git" --argjson deny "$DENY_JSON" '
  def rule(p; d): "prefix_rule(pattern = [\(p | map(tojson) | join(", "))], decision = \"\(d)\")";
  def rule(p): rule(p; "allow");
  ($cmds | split(" ") | map(select(. != "" and . != "git"))) as $base
  | "# Written by orca-issue-orchestrator init-hub from the Guard allowlist (scripts/guard.sh),",
    "# bash_allow[] in .orca-hub/hub.json, and the permissions.deny list. Re-run init-hub to update.",
    "# The skill scripts (issue-*.sh, frontier.sh) are allowed by basename in the Guard only.",
    ($deny[] | ltrimstr("Bash(") | rtrimstr(" *)") | rule(split(" "); "forbidden")),
    ($base[] | rule([.])),
    ($git | split(" ")[] | select(. != "") | rule(["git", .])),
    (.bash_allow | arrays | map(strings | select(. != "")) | unique[] | . as $x | select($base | any(. == $x) | not) | rule([.]))
' "$STAGE/.orca-hub/hub.json" > "$(staged .codex/rules/orchestrator.rules)" || die "could not build the Codex rules"
stage .codex/rules/orchestrator.rules

# .orca-hub/guard.sh: a copy (not a symlink) with a version marker on line 2.
skill_version="$(sed -n 's/^version: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$SKILL_DIR/SKILL.md" | head -1)"
{
  sed -n 1p "$GUARD_SRC"
  printf '# installed-by: orca-issue-orchestrator init-hub, skill version %s. Do not edit; re-run init-hub to update.\n' "${skill_version:-unknown}"
  sed 1d "$GUARD_SRC"
} > "$(staged .orca-hub/guard.sh)"
chmod 755 "$STAGE/.orca-hub/guard.sh"
stage .orca-hub/guard.sh

# --- plan ---------------------------------------------------------------------

timestamp="$(date +%Y%m%d%H%M%S)"

# backup_name <relative path>: a timestamped name that does not exist yet.
backup_name() {
  local name="$1.bak.$timestamp" n=1
  while [ -e "$hub_real/$name" ] || [ -L "$hub_real/$name" ]; do
    name="$1.bak.$timestamp.$n"
    n=$((n + 1))
  done
  printf '%s\n' "$name"
}

changes=0
if [ "$apply" -eq 1 ]; then
  printf 'init-hub: applying to %s\n' "$hub_path"
else
  printf 'init-hub: plan for %s (dry-run)\n' "$hub_path"
fi

for d in $EMPTY_DIRS; do
  inside_hub "$d/x" || die "$d/ resolves outside the Hub folder"
  if [ -d "$hub_real/$d" ]; then
    printf '  keep    %s/\n' "$d"
  else
    [ -e "$hub_real/$d" ] && die "$d exists and is not a directory"
    changes=$((changes + 1))
    printf '  create  %s/\n' "$d"
    [ "$apply" -eq 1 ] && { mkdir -p "$hub_real/$d" || die "cannot create $d/"; }
  fi
done

i=0
while [ "$i" -lt "${#plan_paths[@]}" ]; do
  rel="${plan_paths[$i]}"
  action="${plan_actions[$i]}"
  i=$((i + 1))
  target="$hub_real/$rel"
  case "$action" in
    keep)
      printf '  keep    %s\n' "$rel"
      continue ;;
    create)
      printf '  create  %s\n' "$rel" ;;
    update)
      backup="$(backup_name "$rel")"
      printf '  update  %s (backup: %s)\n' "$rel" "$backup" ;;
    "append block"|"update block")
      backup="$(backup_name "$rel")"
      printf '  %s %s (backup: %s)\n' "$action" "$rel" "$backup"
      changes=$((changes + 1))
      [ "$apply" -eq 1 ] || continue
      # Copy, then rewrite in place: the file keeps its mode and inode, and a
      # symlink inside the Hub folder is written through.
      cp -p -- "$target" "$hub_real/$backup" || die "cannot back up $rel"
      cat -- "$STAGE/$rel" > "$target" || die "cannot write $rel"
      continue ;;
  esac
  changes=$((changes + 1))
  [ "$apply" -eq 1 ] || continue
  mkdir -p "$(dirname -- "$target")" || die "cannot create the directory of $rel"
  if [ "$action" = update ]; then
    mv -- "$target" "$hub_real/$backup" || die "cannot back up $rel"
  fi
  cp -- "$STAGE/$rel" "$target" || die "cannot write $rel"
  chmod "$(if [ -x "$STAGE/$rel" ]; then echo 755; else echo 644; fi)" "$target"
done

if printf '%s' "$settings_old" | jq -e 'has("agent")' >/dev/null 2>&1; then
  printf '\nWarning: .claude/settings.json sets "agent". init-hub leaves it alone, but it replaces the system prompt of every session in the Hub folder.\n'
fi

for f in $legacy_files; do
  printf '\nNote: %s already holds the instructions an older init-hub wrote without markers. After --apply, delete those lines outside the %s block by hand.\n' "$f" "$BLOCK_START"
done

if [ "$changes" -eq 0 ]; then
  printf '\nNo changes.\n'
elif [ "$apply" -eq 1 ]; then
  printf '\nWrote %d change(s).\n' "$changes"
else
  printf '\nDry-run: nothing written. Re-run with --apply to write %d change(s).\n' "$changes"
fi

# --- next steps -----------------------------------------------------------------

printf '\nNext: edit %s/.orca-hub/hub.json (hub_id, concurrency, repos[], bash_allow[]); see references/hub-json.md.\n' "$hub_path"
printf '\nCodex (unverified; confirm with /status that the sandbox is read-only):\n'
case "$hub_path" in
  *.*)
    printf '  %s contains a dot, so "-c projects.<hub-dir>.trust_level=trusted" cannot name it.\n' "$hub_path"
    printf '  Use a dedicated CODEX_HOME inside the Hub folder instead:\n'
    printf '  orca terminal create --worktree path:%s --command "CODEX_HOME=%s/.codex-home codex --sandbox read-only -a never"\n' "$hub_path" "$hub_path"
    printf '  and trust the Hub folder in %s/.codex-home/config.toml:\n' "$hub_path"
    printf '    [projects."%s"]\n    trust_level = "trusted"\n' "$hub_path"
    printf '  Codex keeps its login under CODEX_HOME, so sign in once there.\n' ;;
  *)
    printf '  orca terminal create --worktree path:%s --command "codex --sandbox read-only -a never -c projects.%s.trust_level=trusted"\n' "$hub_path" "$hub_path" ;;
esac
exit 0
