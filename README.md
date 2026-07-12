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
| `loop-design` | Fill a B-type loop-engineering spec (7 elements) as copy-pasteable output |
| `speech-slides` | Generate PPTX decks for 5-min Monday morning speeches |
| `youtube-slide-maker` | Build Marp slides / clip videos from a YouTube video |
| `skill-vendor` | Vendor an external skill into your repo with license + provenance/attribution |

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
