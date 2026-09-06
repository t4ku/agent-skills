# Marp Slide Template

Marp (Markdown Presentation Ecosystem) でスライド出力。PKMのMarkdown資産と相性◎、Git管理可能。

## Install (one-time)
```bash
npm install -g @marp-team/marp-cli
# or use npx: npx @marp-team/marp-cli slides.md -o slides.pdf
```

## Skeleton

```markdown
---
marp: true
theme: default
paginate: true
size: 16:9
style: |
  section {
    font-family: 'Helvetica', 'Hiragino Sans', sans-serif;
    font-size: 28px;
  }
  h1 { font-size: 48px; color: #2B2B2B; }
  h2 { font-size: 36px; color: #D4882B; }
  img { border-radius: 8px; }
  .cite { font-size: 16px; color: #888; position: absolute; bottom: 20px; }
---

# {{Video Title}}

{{Author}} / {{Channel}}

Source: {{URL}}

---

## 1. {{Slide Title}}

![bg right:60%](frames/01-slide-slug.png)

- Key point A
- Key point B

<div class="cite">@ 00:01:23</div>

---

## 2. {{Slide Title}}

![bg right:60%](frames/02-slide-slug.png)

Summary sentence here.

<div class="cite">@ 00:03:45</div>

---

<!-- closing -->

# Key Takeaways

1. Takeaway one
2. Takeaway two
3. Takeaway three

Source: [{{Video Title}}]({{URL}})
```

## Layout Variants

### A. Frame-left, text-right (default)
```markdown
## Title

![bg left:50%](frames/01.png)

- Bullet A
- Bullet B
```

### B. Full-bleed frame with overlay caption
```markdown
## Title

![bg](frames/01.png)

<div style="background:rgba(0,0,0,0.7); color:white; padding:20px; width:50%; position:absolute; bottom:60px; left:60px;">
  Summary text overlay
</div>
```

### C. Two-frame comparison
```markdown
## Before / After

![w:500](frames/before.png) ![w:500](frames/after.png)

Text beneath
```

### D. Quote card
```markdown
## 

> "Important quote from the speaker."
>
> — Speaker Name @ 00:05:30
```

## Rendering

```bash
# PDF
npx @marp-team/marp-cli slides.md -o slides.pdf

# HTML (interactive, self-contained)
npx @marp-team/marp-cli slides.md -o slides.html --html

# PNG per slide (for SNS)
npx @marp-team/marp-cli slides.md --images png -o slides/
```

## Theme Alignment with Syla Design

Matches `speech-slides` skill palette:
- CREAM `#F5F0E8` — background
- DARK `#2B2B2B` — title text
- AMBER `#D4882B` — accent (section titles)
- BLK `#1A1A1A` — body
- GRY `#999999` — cite/caption

Apply via `style:` block in frontmatter (see Skeleton above).
