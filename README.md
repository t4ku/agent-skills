# t4ku Claude Code Skills

Public skill collection for Claude Code.

## Structure

```
agent-skills/
├── .claude-plugin/
│   └── marketplace.json          # 各プラグインを登録
├── {plugin-name}/                # 1 プラグイン = 1 スキル
│   ├── .claude-plugin/
│   │   └── plugin.json           # name / version / description
│   └── skills/{skill-name}/
│       └── SKILL.md              # 参照ファイル・LICENSE は同ディレクトリに置く
├── CREDITS.md                    # vendored skill の台帳
└── README.md
```

> スキルは `{plugin}/skills/{skill}/SKILL.md` に置くこと。プラグイン直下の `SKILL.md` は
> Claude Code に読み込まれない（`claude --plugin-dir ./<plugin> plugin details <name>` で確認できる）。

## Installation (Public → Marketplace)

```bash
# Add marketplace
/plugin marketplace add t4ku/agent-skills

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
| `show-me` | Explain the current topic visually (pseudocode / call tree / Mermaid / diff / HTML artifact) — vendored from humanlayer/skills, MIT |
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
