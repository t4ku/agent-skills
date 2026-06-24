---
name: speech-slides
version: "0.1.0"
description: Generate PPTX slide decks for 5-minute Monday morning speeches at Syla. Triggered when user asks to create slides, make a presentation, or generate a deck from a speech script. Uses PptxGenJS directly (NOT html2pptx.js). Provides 4 slide template patterns, D3.js chart generation, and AI image integration.
---

# Speech Slides Skill

Generate slide decks from speech scripts in `Projects/syla/syla-monday-morning/`.

## Workflow

1. Read the speech script (## スピーチ原稿 section)
2. Select template pattern (or let user choose)
3. Generate PPTX using PptxGenJS directly (see [references/pptxgenjs-guide.md](references/pptxgenjs-guide.md))
4. For charts: generate with D3.js, embed as SVG/PNG (see [references/d3-charts.md](references/d3-charts.md))
5. For custom images: use AI image generation skill (separate skill)
6. Output PPTX to the speech's directory

## IMPORTANT: Use PptxGenJS directly

Do NOT use the pptx skill's `html2pptx.js` — it has known silent failure issues with environment detection. Instead, use PptxGenJS directly:

```bash
# Ensure pptxgenjs is installed locally in the output directory
cd <output-dir> && npm install pptxgenjs
```

Write a `.mjs` script that imports PptxGenJS and calls `pres.writeFile()` with explicit Promise handling. See [references/pptxgenjs-guide.md](references/pptxgenjs-guide.md) for patterns and helpers.

## Template Patterns

4 patterns available. See [references/templates.md](references/templates.md) for slide-by-slide structure.

| Pattern | Slides | Best For |
|---------|--------|----------|
| **A: Story Arc** | 5-6枚 | 物語型スピーチ（導入→展開→結末） |
| **B: Framework** | 4-5枚 | フレームワーク紹介型（3つのポイント etc.） |
| **C: Contrast** | 4-5枚 | 対比型（Before/After、成功/失敗） |
| **D: Minimal** | 3枚 | インパクト重視（問い→核心→締め） |

## Design System

```javascript
const DESIGN = {
  colors: {
    CREAM: "F5F0E8",   // background
    DARK:  "2B2B2B",   // title/closing slides, callout boxes
    AMBER: "D4882B",   // accent, highlights, table headers
    BLK:   "1A1A1A",   // primary text
    WHT:   "FFFFFF",   // card backgrounds
    RED:   "cc3333",   // negative/failure
    GRN:   "33aa55",   // positive/success
    GRY:   "999999",   // secondary text
    TEAL:  "4DD4D0"    // sparingly, for special highlights
  },
  fonts: {
    heading:  { face: "Arial", size: 36, bold: true },
    subhead:  { face: "Arial", size: 24 },
    body:     { face: "Arial", size: 18 },
    caption:  { face: "Arial", size: 13 },
    quote:    { face: "Arial", size: 18, italic: true }
  },
  layout: "LAYOUT_16x9",  // 10" x 5.63"
  spacing: { margin: 0.8, gap: 0.3 }
};
```

## Slide Types

| Type | Description | PptxGenJS Pattern |
|------|-------------|-------------------|
| `title` | Big text + subtitle, dark bg | `addText` centered, `bg: DARK` |
| `statement` | Large bold statement | `addText` with accent color |
| `two-column` | Left text + right visual | Two `addText`/`addShape` at x=0.8 and x=5.4 |
| `comparison` | Side-by-side cards with color-coded top border | `addShape(ROUNDED_RECTANGLE)` + `addShape(RECTANGLE)` for top bar |
| `framework` | 3 cards in a row | Loop with `x = 0.8 + i * 3.1` |
| `table` | Comparison table | `addTable` with header fill |
| `quote-card` | Large quote, dark bg | `addText` italic, `bg: DARK` |
| `data-point` | Big number + context | Large fontSize number + smaller context |
| `closing` | Memorable line, dark bg | `addText` centered, `bg: DARK` |

## Speech-to-Slides Extraction Rules

1. Extract 1 key message per slide (max 20 words for heading)
2. Use speaker's own words for headings — don't rephrase
3. Include supporting data/quotes as body text
4. Target: 1 slide per minute (5 slides for 5 min)
5. Slides SUPPORT the speaker, don't replace them
6. 60-30-10 color rule: 60% background, 30% text, 10% accent

## Visual Enhancement Options

### Charts (D3.js)
For data-driven slides, generate SVG charts with D3 and embed as images. See [references/d3-charts.md](references/d3-charts.md).

### AI Images (separate skill)
For custom illustrations/backgrounds, use AI image generation. Prompt patterns:
- Hero: `"{theme} hero image, professional, 16:9, high quality"`
- Icon: `"minimal icon for {concept}, flat design, transparent background"`
- Background: `"{theme} abstract background, subtle, suitable for text overlay"`
