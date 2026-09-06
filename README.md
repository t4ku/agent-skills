# t4ku Claude Code Skills

Public skill collection for Claude Code.

## Structure

```
agent-skills/
├── .claude-plugin/
│   └── marketplace.json          # カテゴリ単位でスキルをまとめて登録
├── skills/{skill-name}/
│   └── SKILL.md                  # 参照ファイル・LICENSE は同ディレクトリに置く
├── CREDITS.md                    # vendored skill の台帳
└── README.md
```

スキルは `skills/{name}/SKILL.md` にフラットに並べ、**カテゴリは marketplace.json だけで表現する**
（`source: "./"` + `strict: false` + `skills: [...]`）。分類を変えたくなったら JSON の配列を
動かすだけで済み、ファイルは動かさない。

## Installation (Public → Marketplace)

```bash
# Add marketplace
/plugin marketplace add t4ku/agent-skills

# Install a category
/plugin install engineering@t4ku-skills
```

## Categories

| Plugin | Skills | 何のためのカテゴリか |
|--------|--------|----------------------|
| `engineering` | `add-github-permalinks` / `show-me` | 開発作業そのものを助ける |
| `agent-lab` | `loop-design` / `skill-vendor` | エージェント・スキルを作る側 |
| `presentation` | `speech-slides` / `youtube-slide-maker` | 人に見せる資料を作る |
| `integrations` | `airbnb-adr-simulator` | 外部サービスの API を叩く / 操作する |

## Available Skills

| Skill | Category | Description |
|-------|----------|-------------|
| `add-github-permalinks` | engineering | Add permanent GitHub URLs to documentation |
| `show-me` | engineering | Explain the current topic visually (pseudocode / call tree / Mermaid / diff / HTML artifact) — vendored from humanlayer/skills, MIT |
| `loop-design` | agent-lab | Fill a B-type loop-engineering spec (7 elements) as copy-pasteable output |
| `skill-vendor` | agent-lab | Vendor an external skill into your repo with license + provenance/attribution |
| `speech-slides` | presentation | Generate PPTX decks for 5-min Monday morning speeches |
| `youtube-slide-maker` | presentation | Build Marp slides / clip videos from a YouTube video |
| `airbnb-adr-simulator` | integrations | Fetch Airbnb ADR / occupancy / monthly revenue estimates for an area |

---

## Skill Repository Pattern

```
{org}/agent-skills                 # Public → Marketplace
{org}/agent-skills-private         # Private → Symlink
{org}/agent-skills-{project}       # Project-specific
```

### Public (Marketplace)
```bash
/plugin marketplace add {org}/agent-skills
/plugin install {category}@{marketplace}
```

### Private (Symlink)
```bash
ln -s ~/Code/{org}/claude-code-skills-private/{skill} ~/.claude/skills/
```
