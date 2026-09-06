---
name: add-github-permalinks
description: >
  Add GitHub permalinks with fixed SHA/commit references to research documentation
  containing code snippets. Use when writing technical docs with code examples,
  creating investigation/research docs that reference source files, user asks to
  "add permalinks" or "add GitHub links", documenting code research findings with
  file:line references, or creating audit trails needing permanent code references.
  Triggers on "add github links", "add permalinks", "link to source", "make code
  references permanent".
---

# Add GitHub Permalinks

Add permanent GitHub file URLs to research documentation so code references don't break when files change.

## Workflow

### 1. Identify Repositories

Scan the document for code references to determine which repositories are involved:

```
# Common patterns to detect:
repos/{repo}/path/to/file.rb:123     → submodule repo
app/models/user.rb:45                → current repo
commit abc123 in org/repo            → external repo
```

### 2. Get SHA for Each Repository

```bash
# For submodule repos
cd repos/{repo} && git rev-parse HEAD

# For current repo
git rev-parse HEAD

# For historical commits - use the commit SHA directly
```

### 3. Add Permalinks to Code Blocks

Transform code block comments from local paths to GitHub permalinks:

**Before:**
```ruby
# app/models/user.rb:45-50
def example_method
  # implementation
end
```

**After:**
```ruby
# app/models/user.rb:45-50
# https://github.com/{org}/{repo}/blob/{SHA}/app/models/user.rb#L45-L50
def example_method
  # implementation
end
```

### 4. Update Reference Tables

Convert plain file paths to clickable markdown links:

**Before:**
| File | Line | Content |
|------|------|---------|
| `app/models/user.rb` | 45 | method definition |

**After:**
| File | Line | Content |
|------|------|---------|
| [`app/models/user.rb`](https://github.com/{org}/{repo}/blob/{SHA}/app/models/user.rb#L45) | 45 | method definition |

### 5. Add Reference SHAs Header

Add a reference section at the top of Technical Notes or similar sections:

```markdown
> **Reference SHAs (Permalinks):**
> - **{repo}**: [`{short_sha}`](https://github.com/{org}/{repo}/tree/{SHA}) (YYYY-MM-DD)
```

## Permalink Format

```
https://github.com/{org}/{repo}/blob/{SHA}/{path}#L{start}-L{end}
```

| Component | Example | Notes |
|-----------|---------|-------|
| org | `myorg` | GitHub organization or username |
| repo | `myrepo` | Repository name |
| SHA | `c617ebdcda...` | Full or short (10+ chars) commit SHA |
| path | `app/models/user.rb` | File path from repo root |
| #L{n} | `#L45` | Single line anchor |
| #L{n}-L{m} | `#L45-L50` | Line range anchor |

## Checklist

- [ ] Identify all repositories referenced in document
- [ ] Get current HEAD SHA for each repo (or use historical commit SHA if specified)
- [ ] Add permalink comment below file path comments in code blocks
- [ ] Convert file paths in evidence/reference tables to clickable links
- [ ] Add Reference SHAs section documenting which commits are used
- [ ] Update document changelog noting permalink addition
