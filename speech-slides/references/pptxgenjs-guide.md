# PptxGenJS Direct Usage Guide

## Why NOT html2pptx.js

html2pptx.js has known environment detection issues (GitHub issue #277, #531) causing silent failures. Use PptxGenJS directly.

## Setup

```bash
cd <project-dir>
npm init -y
npm install pptxgenjs
```

## Script Template

Every slide generation script follows this pattern. Save as `.mjs` in the output directory.

```javascript
import PptxGenJS from "pptxgenjs";

// Design tokens
const C = {
  CREAM: "F5F0E8", DARK: "2B2B2B", AMBER: "D4882B",
  BLK: "1A1A1A", WHT: "FFFFFF", RED: "cc3333",
  GRN: "33aa55", GRY: "999999", TEAL: "4DD4D0"
};

// Helper: rounded rectangle card
function box(slide, pres, x, y, w, h, fill, topBarColor) {
  slide.addShape(pres.shapes.ROUNDED_RECTANGLE, {
    x, y, w, h, fill: { color: fill }, rectRadius: 0.1
  });
  if (topBarColor) {
    slide.addShape(pres.shapes.RECTANGLE, {
      x, y, w, h: 0.07, fill: { color: topBarColor }
    });
  }
}

// Helper: callout box (dark background with text)
function callout(slide, pres, x, y, w, h, textParts) {
  box(slide, pres, x, y, w, h, C.DARK);
  slide.addText(textParts, { x: x + 0.2, y: y + 0.1, w: w - 0.4, h: h - 0.2 });
}

// Main
const pres = new PptxGenJS();
pres.layout = "LAYOUT_16x9";

// === Add slides here ===

// Title slide
let s = pres.addSlide();
s.background = { color: C.DARK };
s.addText([
  { text: "Title Here\n", options: { fontSize: 36, color: C.WHT, bold: true } },
  { text: "Accent Part", options: { fontSize: 36, color: C.AMBER, bold: true } }
], { x: 0.8, y: 1.5, w: 8.5, h: 2, align: "center" });

// Closing slide
s = pres.addSlide();
s.background = { color: C.DARK };
s.addText("Closing statement here.", {
  x: 0.8, y: 1.5, w: 8.5, h: 2,
  fontSize: 32, bold: true, color: C.WHT, align: "center"
});

// Save — MUST await the Promise
await pres.writeFile({ fileName: "./output.pptx" });
console.log("OK: output.pptx");
```

## API Quick Reference

### Shapes
```javascript
pres.shapes.RECTANGLE          // 矩形
pres.shapes.ROUNDED_RECTANGLE  // 角丸矩形
pres.shapes.OVAL               // 楕円
pres.shapes.LINE               // 線
```

### Text with mixed formatting
```javascript
slide.addText([
  { text: "Normal ", options: { fontSize: 18, color: "1A1A1A" } },
  { text: "Bold",   options: { fontSize: 18, color: "D4882B", bold: true } },
  { text: " text",  options: { fontSize: 18, color: "1A1A1A" } }
], { x: 0.8, y: 1, w: 8.5, h: 0.8 });
```

### Tables
```javascript
slide.addTable([
  // Header row (with fill)
  [
    { text: "Header 1", options: { bold: true, color: "FFFFFF", fill: { color: "D4882B" } } },
    { text: "Header 2", options: { bold: true, color: "FFFFFF", fill: { color: "D4882B" } } }
  ],
  // Data rows
  ["Cell 1", { text: "Cell 2", options: { bold: true, color: "33aa55" } }]
], {
  x: 0.8, y: 1.3, w: 8.5,
  fontSize: 16, color: "1A1A1A",
  border: { type: "solid", pt: 0.5, color: "DDDDDD" },
  colW: [4.25, 4.25]
});
```

### Images
```javascript
// From file
slide.addImage({ path: "./chart.png", x: 1, y: 1.5, w: 8, h: 4 });

// From base64
slide.addImage({ data: "data:image/png;base64,...", x: 1, y: 1.5, w: 8, h: 4 });

// From URL
slide.addImage({ path: "https://example.com/img.png", x: 1, y: 1.5, w: 8, h: 4 });
```

### Native Charts (simple cases — no D3 needed)
```javascript
slide.addChart(pres.charts.BAR, [
  { name: "Series", labels: ["Q1","Q2","Q3"], values: [100, 150, 200] }
], {
  x: 1, y: 1.5, w: 8, h: 4,
  showValue: true, catAxisOrientation: "minMax"
});
```

## Common Patterns

### Comparison cards (red vs green)
```javascript
// Left card (failure)
box(s, pres, 0.8, 1.3, 3.8, 2.8, C.WHT, C.RED);
s.addText("Label", { x: 1, y: 1.5, w: 3.4, fontSize: 16, color: C.BLK });
s.addText("BIG NUMBER", { x: 1, y: 2, w: 3.4, fontSize: 36, bold: true, color: C.RED });

// Right card (success)
box(s, pres, 5.4, 1.3, 3.8, 2.8, C.WHT, C.GRN);
s.addText("Label", { x: 5.6, y: 1.5, w: 3.4, fontSize: 16, color: C.BLK });
s.addText("BIG NUMBER", { x: 5.6, y: 2, w: 3.4, fontSize: 36, bold: true, color: C.GRN });
```

### 3-column framework cards
```javascript
const items = [["Title1","Desc1"],["Title2","Desc2"],["Title3","Desc3"]];
items.forEach(([title, desc], i) => {
  const x = 0.8 + i * 3.1;
  box(s, pres, x, 1.3, 2.8, 2.2, C.WHT);
  s.addText(title, { x: x+0.2, y: 1.5, w: 2.4, fontSize: 18, bold: true, color: C.AMBER, align: "center" });
  s.addText(desc, { x: x+0.2, y: 2.1, w: 2.4, fontSize: 14, color: C.BLK, align: "center" });
});
```

### Dark callout with quote
```javascript
box(s, pres, 0.8, 3.8, 8.5, 0.8, C.DARK);
s.addText([
  { text: "Quote text ", options: { fontSize: 14, color: C.CREAM } },
  { text: "accent word", options: { fontSize: 14, color: C.AMBER, bold: true } }
], { x: 1, y: 3.9, w: 8, h: 0.6 });
```
