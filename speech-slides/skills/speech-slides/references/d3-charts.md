# D3.js Charts for Slides

Generate SVG charts with D3.js and embed in PPTX slides as images.

## When to Use

- **D3.js**: Custom visualizations, complex layouts, styled charts matching the design system
- **PptxGenJS native charts**: Simple bar/pie/line — less setup, smaller file size

## Setup

```bash
npm install d3 sharp  # sharp for SVG→PNG conversion
```

## SVG → PNG → PPTX Pipeline

```javascript
import * as d3 from "d3";
import { JSDOM } from "jsdom";  // npm install jsdom
import sharp from "sharp";
import { writeFileSync } from "fs";

// D3 needs a DOM in Node.js
const dom = new JSDOM("<!DOCTYPE html><html><body></body></html>");
const document = dom.window.document;

// Design tokens (match slide design system)
const C = {
  AMBER: "#D4882B", BLK: "#1A1A1A", GRY: "#999999",
  RED: "#cc3333", GRN: "#33aa55", CREAM: "#F5F0E8"
};

function createBarChart(data, { width = 800, height = 400, title = "" } = {}) {
  const margin = { top: 40, right: 20, bottom: 40, left: 60 };
  const w = width - margin.left - margin.right;
  const h = height - margin.top - margin.bottom;

  const svg = d3.select(document.body).append("svg")
    .attr("xmlns", "http://www.w3.org/2000/svg")
    .attr("width", width).attr("height", height)
    .style("font-family", "Arial, sans-serif");

  // Background
  svg.append("rect").attr("width", width).attr("height", height).attr("fill", C.CREAM);

  // Title
  if (title) {
    svg.append("text").attr("x", margin.left).attr("y", 28)
      .attr("font-size", 18).attr("font-weight", "bold").attr("fill", C.BLK)
      .text(title);
  }

  const g = svg.append("g").attr("transform", `translate(${margin.left},${margin.top})`);

  const x = d3.scaleBand().domain(data.map(d => d.label)).range([0, w]).padding(0.3);
  const y = d3.scaleLinear().domain([0, d3.max(data, d => d.value) * 1.1]).range([h, 0]);

  // Bars
  g.selectAll("rect").data(data).join("rect")
    .attr("x", d => x(d.label)).attr("y", d => y(d.value))
    .attr("width", x.bandwidth()).attr("height", d => h - y(d.value))
    .attr("fill", (d, i) => d.color || C.AMBER)
    .attr("rx", 4);

  // Value labels
  g.selectAll(".val").data(data).join("text")
    .attr("x", d => x(d.label) + x.bandwidth() / 2)
    .attr("y", d => y(d.value) - 8)
    .attr("text-anchor", "middle").attr("font-size", 14).attr("fill", C.BLK)
    .text(d => d.value);

  // Axes
  g.append("g").attr("transform", `translate(0,${h})`).call(d3.axisBottom(x))
    .selectAll("text").attr("fill", C.BLK).attr("font-size", 13);
  g.append("g").call(d3.axisLeft(y).ticks(5))
    .selectAll("text").attr("fill", C.GRY).attr("font-size", 12);

  const svgString = svg.node().outerHTML;
  svg.remove();
  return svgString;
}

// Convert SVG string to PNG file
async function svgToPng(svgString, outputPath, width = 800) {
  await sharp(Buffer.from(svgString))
    .resize(width)
    .png()
    .toFile(outputPath);
}

// Usage
const chartSvg = createBarChart([
  { label: "W03", value: 43, color: C.RED },
  { label: "W04", value: 71, color: C.GRN },
  { label: "W05", value: 29, color: C.RED },
  { label: "W06", value: 14, color: C.RED },
  { label: "W07", value: 29, color: C.AMBER }
], { title: "Morning Journal 達成率 (%)" });

await svgToPng(chartSvg, "./chart-journal.png");

// Then in PptxGenJS:
// slide.addImage({ path: "./chart-journal.png", x: 1, y: 1.5, w: 8, h: 4 });
```

## Chart Types

### Line Chart (trends)
```javascript
function createLineChart(data, { width = 800, height = 400, title = "" } = {}) {
  // data: [{ x: "Jan", y: 100 }, ...]
  const margin = { top: 40, right: 20, bottom: 40, left: 60 };
  const w = width - margin.left - margin.right;
  const h = height - margin.top - margin.bottom;

  const svg = d3.select(document.body).append("svg")
    .attr("xmlns", "http://www.w3.org/2000/svg")
    .attr("width", width).attr("height", height)
    .style("font-family", "Arial, sans-serif");

  svg.append("rect").attr("width", width).attr("height", height).attr("fill", C.CREAM);
  if (title) svg.append("text").attr("x", margin.left).attr("y", 28)
    .attr("font-size", 18).attr("font-weight", "bold").attr("fill", C.BLK).text(title);

  const g = svg.append("g").attr("transform", `translate(${margin.left},${margin.top})`);
  const xScale = d3.scalePoint().domain(data.map(d => d.x)).range([0, w]);
  const yScale = d3.scaleLinear().domain([0, d3.max(data, d => d.y) * 1.1]).range([h, 0]);

  const line = d3.line().x(d => xScale(d.x)).y(d => yScale(d.y)).curve(d3.curveMonotoneX);
  g.append("path").datum(data).attr("d", line)
    .attr("fill", "none").attr("stroke", C.AMBER).attr("stroke-width", 3);

  g.selectAll("circle").data(data).join("circle")
    .attr("cx", d => xScale(d.x)).attr("cy", d => yScale(d.y))
    .attr("r", 5).attr("fill", C.AMBER);

  g.append("g").attr("transform", `translate(0,${h})`).call(d3.axisBottom(xScale));
  g.append("g").call(d3.axisLeft(yScale).ticks(5));

  const result = svg.node().outerHTML;
  svg.remove();
  return result;
}
```

### Comparison Chart (two series)
```javascript
function createComparisonChart(data1, data2, labels, { width = 800, height = 400, title = "", legend = ["A","B"] } = {}) {
  // Grouped bar chart with two series
  // data1, data2: arrays of numbers, labels: category labels
  // ... similar structure, use d3.scaleBand with inner padding for grouping
}
```

## Native PptxGenJS Charts (simpler cases)

For simple charts, skip D3 and use PptxGenJS built-in:

```javascript
// Bar chart
slide.addChart(pres.charts.BAR, [
  { name: "達成率", labels: ["W03","W04","W05"], values: [43, 71, 29] }
], { x: 1, y: 1.5, w: 8, h: 4, showValue: true, valAxisMaxVal: 100 });

// Line chart
slide.addChart(pres.charts.LINE, [
  { name: "Growth", labels: ["Jan","Feb","Mar"], values: [10, 25, 45] }
], { x: 1, y: 1.5, w: 8, h: 4, lineSmooth: true });

// Pie chart
slide.addChart(pres.charts.PIE, [
  { name: "Distribution", labels: ["A","B","C"], values: [40, 35, 25] }
], { x: 2, y: 1, w: 6, h: 4, showPercent: true });
```

## Decision Guide

| Need | Use |
|------|-----|
| Simple bar/line/pie | PptxGenJS native `addChart` |
| Custom styled chart matching design system | D3 → PNG → `addImage` |
| Animated/interactive preview | D3 in HTML artifact (browser only) |
| Complex viz (treemap, sankey, network) | D3 → PNG → `addImage` |
