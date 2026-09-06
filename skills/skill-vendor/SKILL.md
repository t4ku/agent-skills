---
name: skill-vendor
description: >
  Vendor (copy-import) a single external Claude Code skill into your own skills
  repo correctly — with license compliance and full provenance/attribution.
  Deterministic, idempotent primitive: given an upstream ref (owner/repo/path@sha
  or a GitHub URL) it fetches the skill, detects and gates on the license, copies
  the folder, injects a provenance frontmatter block (license + metadata:
  author/source/upstream_commit/vendored_at/provenance), ships the upstream
  LICENSE, adds a ## Credits section, and records a CREDITS.md ledger entry.
  Use when the user asks to "vendor a skill", "import a skill", "clone a skill",
  "borrow someone's skill", "add an external skill with attribution/credit", or
  スキルを取り込む / vendoring / 他人のスキルを自分のリポに取り込む. This is the
  import primitive that a skill-scout/curator orchestrator calls; it does NOT
  discover or evaluate — it correctly imports ONE skill you already chose.
---

# skill-vendor

Copy an external skill into your own collection **the right way**: license-clean and fully attributed.

Not a submodule. Not a raw `cp`. This is the primitive that turns "I want that skill" into a vendored copy you can edit, pinned to an upstream commit, with the credit and license obligations satisfied so the import is safe to publish.

> **Scope**: imports exactly ONE skill you have already chosen. It does no discovery, ranking, or safety evaluation of *whether* to adopt — that is the orchestrator's job (see `## Composition` below). Keep this primitive deterministic and idempotent.

## When to use

- The user picked an upstream skill and wants it in their own repo (`t4ku/agent-skills`, a private collection, `.claude/skills/`, …).
- You are a `skill-scout`/curator step that has shortlisted a candidate and now needs to import it with provenance.

## Inputs

```
/skill-vendor <upstream-ref> [--into <target-skills-dir>] [--as <local-name>] [--adapted]
```

- `<upstream-ref>` — one of:
  - `owner/repo/path/to/skill@<sha-or-tag-or-branch>` (SHA strongly preferred)
  - a GitHub URL to the skill folder (blob/tree URL; extract owner/repo/ref/path)
- `--into` — target skills dir. Default: the current repo's convention (`skills/<skill>/` for a marketplace repo like `t4ku/agent-skills`, or `.claude/skills/<skill>/` for a vault). Infer from where you are.
- `--as` — rename on import (default: keep upstream folder name).
- `--adapted` — you intend to modify after import; sets `provenance: adapted` (default `verbatim`).

## Workflow

### 1. Resolve ref and PIN a commit SHA
Resolve the ref to a **concrete commit SHA** — this is non-negotiable. SKILL.md has no semver, no version field, and no dependency constraints, so **the SHA is the only version**. If given a branch/tag, resolve it to the SHA it points at *now* and record that SHA (not the branch name).

```bash
# via git (sparse)  — preferred, gets the real tree + SHA
git clone --no-checkout --depth 1 --filter=blob:none <repo-url> <tmp>
git -C <tmp> sparse-checkout set <path>
git -C <tmp> checkout <ref>
SHA=$(git -C <tmp> rev-parse HEAD)
# or via gh api if git is unavailable:  gh api repos/<owner>/<repo>/commits/<ref> --jq .sha
```

### 2. Detect license and GATE  ⛔
Read the license of the **source repo** (root `LICENSE`/`LICENSE.md`/`COPYING`, `package.json` `license`, or SPDX header in SKILL.md). Then:

| Detected | Action |
|---|---|
| **MIT / BSD-2 / BSD-3 / ISC / Apache-2.0 / 0BSD / Unlicense / CC0** | ✅ proceed. (Apache-2.0: also carry any `NOTICE` file.) |
| **GPL / LGPL / AGPL / MPL / other copyleft** | ⛔ **STOP.** Do not auto-vendor. Report the license and hand the adoption decision back to the human (copyleft can impose obligations on the consuming repo). |
| **No license found** | ⛔ **STOP.** "No license" = all rights reserved by default; vendoring is not permitted. Report and ask the human to (a) confirm they obtained permission, or (b) request the author add a license upstream. |

**Never** downgrade or invent a license. If detection is ambiguous, treat as "no license found" and stop.

### 3. Copy the skill folder
Copy the upstream skill directory to `<target>/<local-name>/` (real files, **not** a submodule — you want an editable, curatable copy). Preserve the folder's own files (SKILL.md, templates, scripts, assets).

### 4. Inject the provenance frontmatter block
Merge these keys into the vendored SKILL.md frontmatter. Keep the upstream `name`/`description` (adjust `name` only if `--as` renamed it). Put attribution under `metadata:` — top-level custom keys can be rejected by strict schemas; `license:` top-level is allowed.

```yaml
name: <name>                      # upstream, or --as override
description: >
  <upstream description, unchanged>
license: MIT                      # the DETECTED SPDX id (step 2)
metadata:
  author: <upstream author/owner>
  source: https://github.com/<owner>/<repo>/tree/<sha>/<path>
  upstream_commit: <full 40-char SHA>       # the pin from step 1
  vendored_at: "YYYY-MM-DD"                  # today
  vendored_by: <your handle>                 # e.g. t4ku
  provenance: verbatim                       # or "adapted" (--adapted)
```

### 5. Ship the upstream LICENSE  (the legal core)
Satisfy the license's attribution requirement — this is the one hard obligation. Do **one** of:
- copy the upstream license text (with its original copyright line, verbatim) to `<target>/<local-name>/LICENSE`, **or**
- append an entry (skill name, upstream URL, SHA, full license text) to a repo-root `THIRD-PARTY-LICENSES.md`.

Prefer the per-skill `LICENSE` file — it travels with the skill if someone re-vendors it downstream.

### 6. Add a `## Credits` section to the SKILL.md body
Append at the end of the vendored SKILL.md:

```markdown
## Credits

Vendored from [`<owner>/<repo>`](<source-url>) by @<author> — <SPDX license>.
Pinned to commit `<sha>`, imported <YYYY-MM-DD>.
Provenance: verbatim.   <!-- or: adapted — see changes below -->
<!-- if adapted, list the changes made after import -->
```

### 7. Record the ledger entry
Append one row to a repo-root `CREDITS.md` (human-readable) — create it if absent:

```markdown
| Skill | Upstream | Author | License | Commit | Vendored | Provenance |
|-------|----------|--------|---------|--------|----------|------------|
| `<local-name>` | <source-url> | @<author> | MIT | `<sha7>` | YYYY-MM-DD | verbatim |
```

Optionally also write a machine-readable `state.json` keyed by local-name → `{source, upstream_commit, vendored_at, provenance}` so a `skill-scout` can diff against upstream later. (Skip if no orchestrator consumes it.)

### 8. Report
Emit: target path, pinned SHA, detected license, verbatim/adapted, and the files written (SKILL.md, LICENSE, CREDITS.md row). If a marketplace/collection manifest exists (`.claude-plugin/marketplace.json`, README skills table), remind the user to register the new skill there — do not silently mutate the manifest unless asked.

## Safety gates (do not skip)

- **License gate** (step 2): copyleft or no-license → STOP, hand to human. Zero exceptions.
- **SHA pin** (step 1): always record a concrete commit SHA; never pin to a moving branch/tag name.
- **Idempotent**: if `<target>/<local-name>/` already exists, compare its recorded `upstream_commit`. Same SHA → no-op (report "already vendored at <sha>"). Different SHA → treat as an **update**: show the diff intent and refresh provenance (`vendored_at`, `upstream_commit`), do not blindly overwrite local `--adapted` edits (warn if provenance was `adapted`).
- **provenance flag**: mark `verbatim` vs `adapted` honestly so a later upstream diff is meaningful.
- **No secret/PII carry**: skip any upstream file that isn't part of the skill (stray `.env`, credentials); vendor only the skill's own files.

## Composition

This is a leaf primitive. An orchestrator (`skill-scout` / curator) decides *what* and *when*:
`scout` monitors upstream repos on a schedule → diffs new/changed SKILL.md since last-seen SHA → deep-research evaluates each candidate (fit, dedupe, safety) → for each accepted candidate, **calls `skill-vendor` with the pinned ref** → opens a PR (human-merge gate). `skill-vendor` never loops and never decides adoption — that separation keeps this step deterministic and testable.

## Why vendor, not submodule

Submodules give you upstream-tracking but are read-only-in-spirit (recursive-clone friction, awkward to edit for a curated collection). Vendor (copy) when you want to **own and edit** the skill in your collection; use a submodule/`git subtree` only when you plan to push changes back upstream. This skill implements the vendor path.
