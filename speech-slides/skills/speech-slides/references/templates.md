# Speech Slide Templates

4 patterns for 5-minute Monday morning speeches. All use the Syla speech design system.

## Common CSS Base

All templates share this base. Paste at top of every HTML file.

```css
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: "Helvetica Neue", Arial, sans-serif; }

.slide {
  width: 1280px; height: 720px;
  padding: 50px 60px;
  position: relative;
  page-break-after: always;
  overflow: hidden;
}

/* Backgrounds */
.bg-cream { background: #F5F0E8; color: #1A1A1A; }
.bg-dark  { background: #2B2B2B; color: #F5F0E8; }
.bg-white { background: #FFFFFF; color: #1A1A1A; }

/* Typography */
h1 { font-size: 40px; font-weight: 700; line-height: 1.3; margin-bottom: 24px; }
h2 { font-size: 28px; font-weight: 600; line-height: 1.4; margin-bottom: 16px; }
p, li { font-size: 20px; line-height: 1.6; }
.subtitle { font-size: 22px; color: #666; margin-top: 8px; }

/* Accent */
.accent { color: #D4882B; }
.accent-bg { background: #D4882B; color: white; padding: 4px 12px; display: inline-block; }
.highlight { color: #4DD4D0; }
.underline-accent { border-bottom: 4px solid #D4882B; padding-bottom: 2px; }

/* Layout helpers */
.two-col { display: flex; gap: 40px; align-items: flex-start; }
.two-col > * { flex: 1; }
.center-v { display: flex; flex-direction: column; justify-content: center; height: 100%; }
.bottom-right { position: absolute; bottom: 20px; right: 30px; font-size: 12px; color: #999; }

/* Cards & boxes */
.card {
  background: white; border-radius: 8px; padding: 24px;
  box-shadow: 0 2px 8px rgba(0,0,0,0.08);
}
.callout {
  background: #2B2B2B; color: #F5F0E8; border-radius: 8px;
  padding: 20px 24px; font-size: 18px; line-height: 1.5;
}
.quote-box {
  border-left: 4px solid #D4882B; padding-left: 20px;
  font-style: italic; font-size: 22px;
}

/* Table */
table { width: 100%; border-collapse: collapse; font-size: 18px; }
th { background: #D4882B; color: white; padding: 12px 16px; text-align: left; }
td { padding: 12px 16px; border-bottom: 1px solid #ddd; }
tr:nth-child(even) { background: #f9f6f0; }
```

---

## Pattern A: Story Arc (物語型) — 5-6 slides

Best for: narrative speeches with personal stories (e.g. 不完全な行動, 恐怖は成長のシグナル)

```
Slide 1: Title (bg-dark or bg-cream with background image)
  - Big title (speech theme)
  - Subtitle (speaker / date)

Slide 2: Hook - Shocking Fact or Question (bg-cream)
  - Large statement or question as h1
  - Supporting data or context below
  - Optional: simple icon or illustration

Slide 3: Story + Contrast (bg-cream, two-col)
  - Left: failure story (personal or business)
  - Right: success counter-example
  - Use cards or comparison boxes

Slide 4: Framework / Science (bg-cream)
  - Key concept name as h1
  - Diagram, flowchart, or data visualization
  - Brief explanation text

Slide 5: Action Table (bg-cream)
  - "Before → After" or "Old → New" comparison table
  - 3 rows max
  - Clear, actionable items

Slide 6: Closing Statement (bg-dark or bg-cream with subtle bg)
  - One powerful sentence, large text
  - Minimal decoration
```

### Example: "不完全な行動が完璧な計画を超える"

```html
<!-- Slide 1: Title -->
<div class="slide bg-dark">
  <div class="center-v" style="text-align: center;">
    <h1 style="font-size: 48px; color: #F5F0E8;">
      不完全な行動が、<br><span class="accent">完璧な計画</span>を超える
    </h1>
    <p class="subtitle" style="color: #999; margin-top: 16px;">SYLA 朝礼トーク｜2026.04.13</p>
  </div>
  <div class="bottom-right">© SYLA</div>
</div>

<!-- Slide 2: Hook -->
<div class="slide bg-cream">
  <h1>Nokia: シェア<span class="accent">40%</span> → <span class="accent">3%</span></h1>
  <div class="two-col" style="margin-top: 32px;">
    <div>
      <h2>2007年</h2>
      <p>「iPhoneはおもちゃだ。<br>コピペすらできない」</p>
      <p style="margin-top: 16px; color: #999;">— Nokia社内の反応</p>
    </div>
    <div>
      <h2>2013年</h2>
      <p>Appleは不完全なまま出して、<br>毎年アップデートした</p>
      <p style="margin-top: 16px; font-weight: 700;">Nokiaは完璧を守り、<br>世界から取り残された</p>
    </div>
  </div>
  <div class="bottom-right">© SYLA</div>
</div>

<!-- Slide 3: Contrast -->
<div class="slide bg-cream">
  <h1>同じ人間、同じ時期、<span class="accent">真逆の結果</span></h1>
  <div class="two-col" style="margin-top: 24px;">
    <div class="card" style="border-top: 4px solid #cc3333;">
      <h2>❌ AI設計スペック</h2>
      <p style="font-size: 48px; font-weight: 700; color: #cc3333;">3週間</p>
      <p>「もっと設計を詰めないと…」<br>→ W42→W43→W44 延期</p>
    </div>
    <div class="card" style="border-top: 4px solid #33aa55;">
      <h2>✅ Shareholder Coin</h2>
      <p style="font-size: 48px; font-weight: 700; color: #33aa55;">1週間</p>
      <p>839件・730万円分を完遂<br>→ 締切+まず動く+途中修正</p>
    </div>
  </div>
  <div class="bottom-right">© SYLA</div>
</div>

<!-- Slide 4: Framework -->
<div class="slide bg-cream">
  <h1>失敗を<span class="accent">小さく</span>する知恵</h1>
  <div style="display: flex; gap: 24px; margin-top: 32px;">
    <div class="card" style="flex:1; text-align:center;">
      <p style="font-size: 36px;">🚀</p>
      <h2>まず動く</h2>
      <p>80%の情報で決断<br>松下の40/60ルール</p>
    </div>
    <div class="card" style="flex:1; text-align:center;">
      <p style="font-size: 36px;">🐤</p>
      <h2>小さく試す</h2>
      <p>カナリアリリース<br>まず5%から始める</p>
    </div>
    <div class="card" style="flex:1; text-align:center;">
      <p style="font-size: 36px;">🔄</p>
      <h2>素早く学ぶ</h2>
      <p>OODAループ<br>PDCAより速く回す</p>
    </div>
  </div>
  <div class="callout" style="margin-top: 24px;">
    柳井正：「失敗から学ぶ速度を、競合の<strong>10倍</strong>にする」
  </div>
  <div class="bottom-right">© SYLA</div>
</div>

<!-- Slide 5: Action -->
<div class="slide bg-cream">
  <h1>問いかけを<span class="accent">変える</span></h1>
  <table style="margin-top: 32px;">
    <tr><th style="width:50%">これまで</th><th>これから</th></tr>
    <tr><td>「完璧か？」</td><td><strong>「これで学べるか？」</strong></td></tr>
    <tr><td>「失敗しないか？」</td><td><strong>「失敗を小さくできるか？」</strong></td></tr>
    <tr><td>「全部揃ったか？」</td><td><strong>「今ある手段で始められるか？」</strong></td></tr>
  </table>
  <div class="bottom-right">© SYLA</div>
</div>

<!-- Slide 6: Closing -->
<div class="slide bg-dark">
  <div class="center-v" style="text-align: center;">
    <h1 style="font-size: 44px; color: #F5F0E8;">
      完璧な一歩を待っていたら、<br>永遠にその場所に<span class="accent">立ったまま</span>です。
    </h1>
  </div>
  <div class="bottom-right" style="color: #666;">© SYLA</div>
</div>
```

---

## Pattern B: Framework (フレームワーク紹介型) — 4-5 slides

Best for: concept-driven speeches with numbered points (e.g. セルフコントロール5領域, パワーパートナー3要素)

```
Slide 1: Title + Myth-Busting Hook (bg-cream)
  - Conventional wisdom as h1
  - "But actually..." reveal

Slide 2: Framework Diagram (bg-cream)
  - Visual representation of the framework
  - Numbered items, concentric circles, or layered diagram
  - Highlight the key element

Slide 3: Personal Story + Data (bg-cream, two-col)
  - Left: personal anecdote with specific numbers
  - Right: supporting data or quote

Slide 4: Actionable Technique (bg-cream)
  - One concrete technique with before/after example
  - Callout box with the key phrase

Slide 5: Closing (bg-dark)
  - Memorable one-liner
```

---

## Pattern C: Contrast (対比型) — 4-5 slides

Best for: before/after, success/failure, old/new comparisons (e.g. 知行ギャップ, 複利効果)

```
Slide 1: Title with Self-Deprecating Hook (bg-cream)
  - Confession or surprising number
  - Sets up the contrast

Slide 2: The Paradox (bg-cream, two-col)
  - Left card: failure case (red accent top-border)
  - Right card: success case (green accent top-border)
  - Same person/timeframe, different results

Slide 3: The Science / Why (bg-cream)
  - Research finding or psychological explanation
  - Data point with big number
  - Quote from authority

Slide 4: The Recovery Story + Action (bg-cream)
  - How the failure was overcome
  - Specific technique to take away
  - Table or bullet list

Slide 5: Closing (bg-dark)
  - Callback to opening confession
  - Warm, encouraging closing line
```

### Example: "知行ギャップ"

```html
<!-- Slide 1: Self-deprecating hook -->
<div class="slide bg-cream">
  <div class="center-v">
    <h1 style="font-size: 44px;">
      Atomic Habitsを朝礼で語った週、<br>
      僕のジャーナル達成率は<span class="accent" style="font-size: 64px;">29%</span>でした
    </h1>
    <p class="subtitle">「知っている」と「できている」のギャップ</p>
  </div>
  <div class="bottom-right">© SYLA</div>
</div>

<!-- Slide 2: Paradox -->
<div class="slide bg-cream">
  <h1>同じ人間の、<span class="accent">同じ週</span></h1>
  <div class="two-col" style="margin-top: 24px;">
    <div class="card" style="border-top: 4px solid #cc3333;">
      <h2>❌ Evening Journal</h2>
      <p style="font-size: 56px; font-weight: 700; color: #cc3333;">0%</p>
      <p>5週連続ゼロ<br>たった3行が書けない</p>
    </div>
    <div class="card" style="border-top: 4px solid #33aa55;">
      <h2>✅ Agent Teams</h2>
      <p style="font-size: 56px; font-weight: 700; color: #33aa55;">6,000</p>
      <p>メッセージ処理<br>AI 3体を同時統率</p>
    </div>
  </div>
  <div class="callout" style="margin-top: 20px;">能力の問題ではない。<strong>仕組み</strong>の問題。</div>
  <div class="bottom-right">© SYLA</div>
</div>

<!-- Slide 3: Science -->
<div class="slide bg-cream">
  <h1>If-Then Planning: 意図→行動は<span class="accent">20〜30%</span></h1>
  <div class="two-col" style="margin-top: 32px;">
    <div>
      <div class="quote-box">
        「やろう」という意図だけでは、<br>7割が行動に移せない
        <p style="font-style: normal; font-size: 16px; color: #999; margin-top: 8px;">— Gollwitzer (1999)</p>
      </div>
      <div class="callout" style="margin-top: 20px;">
        「もし○○なら、△△する」<br>→ 実行率が劇的に向上
      </div>
    </div>
    <div class="card" style="text-align: center;">
      <h2>退職貯蓄の参加率</h2>
      <div style="display: flex; align-items: center; justify-content: center; gap: 16px; margin-top: 16px;">
        <div>
          <p style="font-size: 48px; font-weight: 700; color: #cc3333;">37%</p>
          <p>自分で申込</p>
        </div>
        <p style="font-size: 36px;">→</p>
        <div>
          <p style="font-size: 48px; font-weight: 700; color: #33aa55;">86%</p>
          <p>自動登録</p>
        </div>
      </div>
      <p style="margin-top: 12px; font-size: 16px; color: #666;">仕組みが変わっただけ。意志は同じ。</p>
    </div>
  </div>
  <div class="bottom-right">© SYLA</div>
</div>

<!-- Slide 4: Recovery + Action -->
<div class="slide bg-cream">
  <h1>回復の方法は<span class="accent">シンプル</span>だった</h1>
  <div class="two-col" style="margin-top: 24px;">
    <div>
      <h2>3行 → 1行にしただけ</h2>
      <table style="margin-top: 16px;">
        <tr><th>週</th><th>達成率</th></tr>
        <tr><td>W03</td><td style="color: #cc3333; font-weight: 700;">43%</td></tr>
        <tr><td>W04（1行に変更）</td><td style="color: #33aa55; font-weight: 700;">71%</td></tr>
      </table>
    </div>
    <div>
      <h2>今日からのアクション</h2>
      <div class="card">
        <p><strong>① 2分ルール</strong><br>習慣を2分に縮小する</p>
        <p style="margin-top: 12px;"><strong>② Never Miss Twice</strong><br>1回は事故。2回は新しい習慣。</p>
      </div>
    </div>
  </div>
  <div class="bottom-right">© SYLA</div>
</div>

<!-- Slide 5: Closing -->
<div class="slide bg-dark">
  <div class="center-v" style="text-align: center;">
    <h1 style="font-size: 40px; color: #F5F0E8;">
      知識は<span class="accent">仕組み</span>に変換して初めて、<br>僕たちを助けてくれる。
    </h1>
    <p style="color: #999; margin-top: 24px; font-size: 20px;">
      Atomic Habitsを語って日記が書けなかった僕が言うんだから、間違いありません。
    </p>
  </div>
  <div class="bottom-right" style="color: #666;">© SYLA</div>
</div>
```

---

## Pattern D: Minimal (インパクト重視) — 3 slides

Best for: short speeches, strong single-message talks, when visuals should support not distract.

```
Slide 1: One Big Question or Statement (bg-dark)
  - Full-screen text, centered
  - Maximum 15 words
  - No decoration

Slide 2: The Answer + Evidence (bg-cream)
  - Key insight as h1
  - 1-2 supporting points with data
  - Optional: single diagram or icon

Slide 3: Call to Action (bg-dark)
  - One sentence action item
  - Memorable closing phrase
```

---

## Pattern Selection Guide

| Speech characteristic | Recommended Pattern |
|----------------------|-------------------|
| Personal failure → recovery story | A (Story Arc) or C (Contrast) |
| Teaching a framework (3 points, 5 domains) | B (Framework) |
| Before/After comparison with data | C (Contrast) |
| Strong single message, minimal slides | D (Minimal) |
| Uses business case studies (Kodak, Uniqlo) | A (Story Arc) |
| Self-deprecating humor opening | C (Contrast) |
