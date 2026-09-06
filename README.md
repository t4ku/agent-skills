# t4ku Claude Code Skills

Public skill collection for Claude Code.

## Structure

```
claude-code-skills/
├── .claude-plugin/
│   └── marketplace.json
├── {skill-name}/
│   └── SKILL.md
└── README.md
```

## Installation (Public → Marketplace)

```bash
# Add marketplace
/plugin marketplace add t4ku/claude-code-skills

# Install skill
/plugin install add-github-permalinks
```

## Available Skills

| Skill | Description |
|-------|-------------|
| `add-github-permalinks` | Add permanent GitHub URLs to documentation |
| `show-me` | Explain the current topic visually (pseudocode / call tree / Mermaid / diff / HTML artifact) — vendored from humanlayer/skills, MIT |

---

## Skill Repository Pattern

```
{org}/claude-code-skills           # Public → Marketplace
{org}/claude-code-skills-private   # Private → Symlink
{org}/claude-code-skills-{project} # Project-specific
```

### Public (Marketplace)
```bash
/plugin marketplace add {org}/claude-code-skills
/plugin install {skill-name}
```

### Private (Symlink)
```bash
ln -s ~/Code/{org}/claude-code-skills-private/{skill} ~/.claude/skills/
```
