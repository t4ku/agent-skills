---
name: loop-design
version: "0.1.0"
description: やりたいことを1行で言うと、B 型 loop engineering の 7 要素 (context / feedback / verification gate / termination / error handling / state / cost guard) を埋めた loop spec をコピペ可能な形で生成する。生成した spec は現行 Claude Code の実行プリミティブ (Workflow ツール / /loop skill / ralph-loop plugin / claude -p) に落とせる骨格になる (旧 `claude --goal` は廃止)。10 件 failure mode (F1-F10) の対策フックも自動挿入。Hybrid モード: 1 行入力 → デフォルト埋めで一発出力 → 「ここを調整したい」場所だけ短く聞き直す。Use when ユーザーが「loop を作りたい / loop-design / 自走ループ書いて / Workflow 用の spec 作って / 7 要素埋めて / verification gate ありで」と言ったとき、または `/loop-design` を実行したとき。Loop engineering の理論背景は Cards/loop-engineering-autonomous-agents、失敗モード対策は Cards/loop-failure-modes-mechanism-2026 を参照。
---

# Loop Design Skill — 7 要素を埋めた B 型 loop spec を生成する

## 何をするか

ユーザーが **やりたいこと** (1 行〜数行) を渡すと、**現行 Claude Code の実行プリミティブに落とせる loop spec** を生成する。実行先は `Workflow` ツール (推奨) / `/loop` skill / `ralph-loop` plugin / `claude -p` から、タスク特性で選ぶ。

> ⚠️ 旧版が前提にしていた `claude --goal` / `--max-iterations` は **Claude Code 2.1.185 時点で存在しない**。spec は「設計図」であり、上記プリミティブに転記して走らせる。

- B 型 (end-goal 駆動) のテンプレを基本にしつつ、A 型 (rigid な反復 = `ralph-loop`) も実行プリミティブとして選択可
- **7 要素 + F1-F10 対策フック** を構造として埋める
- **デフォルト埋め先行**、ユーザーが調整したい箇所のみ Hybrid で聞き直す
- 出力は **markdown コードブロック 1 つ**、コピペ即実行可能

## 1 行で

> **prompt engineering ではなく loop engineering を書く** ための spec ジェネレータ。10 件 failure mode の地雷を踏まないように、verification gate と termination condition を機械判定可能な形に整える。

## 起動条件

- `/loop-design <やりたいこと>` のスラッシュコマンド
- ユーザーが自然文で「loop 書いて」「7 要素埋めて」「/goal 用の spec 作って」と言ったとき
- 既存 skill の改善案として「ここを自走化したい」と言ったとき

## 入力フォーマット

```text
/loop-design "<やりたいこと 1 行>"
/loop-design "<やりたいこと>" --max-budget=5 --max-turns=30 --verifier=codex
/loop-design "<やりたいこと>" --interactive   # 7 要素を 1 つずつ聞く
```

| オプション | default | 説明 |
|----------|---------|------|
| (positional) | (必須) | やりたいこと、自然文 1 行 (例: "テストが通るまで src/ を直す") |
| `--max-budget=<usd>` | 5 | コストガード上限 ($USD) |
| `--max-turns=<n>` | 30 | 最大ターン数 |
| `--verifier=<name>` | (auto) | 別モデル verifier 指定。`codex` / `gemini` / `none` / (default: タスクから推定) |
| `--type=deterministic|non-deterministic` | auto | 完了判定の機械化可否 |
| `--interactive` | off | 7 要素を 1 つずつ聞き取り |
| `--no-fail-hooks` | off | F1-F10 対策フックを挿入しない (シンプル版) |

## 出力フォーマット (テンプレート)

```text
# Loop Spec: <slug>

## End Goal
<人間がドメイン知識で定義する到達点。機械的に判定可能な形>

## Termination Condition
- 完了: <Verification Gate を全部 pass>
- 失敗: <連続 N 回失敗 / cost > $X / 最大 M ターン>

## Verification Gates (決定的 ⊃ LLM、決定的を最後段)
### Stage 1 (LLM gate, 確率的)
- <judge model = Haiku 等、別モデル>
- <判定 prompt の骨子>

### Stage 2 (決定的 gate, 二値判定)
- <exit code / git status / regex / JSON schema>

## Feedback Loop
- 各サイクルで上記 gate を再実行
- 失敗時は stderr の最初の 50 行を context に戻す

## State Across Turns
- 進捗: .agent/progress.md (append-only)
- 試した修正: .agent/attempts.jsonl (同じ手を 2 回試さない、hash で dedup)

## Context Management
- auto-compact に任せ、PreCompact / SessionStart(source=compact) フックで CLAUDE.md と本 spec を再注入 (F1 対策)
- 動的タイムスタンプ・ツール順ランダム化を避ける (F10 対策)

## Error Handling
- ツール失敗 → 同じ引数で再試行禁止、代替経路を State に記録
- 壊れた状態を残さない (git stash / revert)
- F2 対策: test 結果は file 経由 (`npm test > test.log 2>&1 || true`)
- F3 対策: OAuth token は serialize 層に永続化

## Cost Guard
- 1 ループ最大 $<max-budget>、最大 <max-turns> ターン
- Tiering: heartbeat=Haiku 4.5 / main=Opus 4.8 / verifier=Haiku 4.5
- F6 対策: /cost を 5 ターン毎に check、超過で停止

## (Optional) Adversarial Verifier (non-deterministic 時)
- maker = Claude (現在のセッション)
- verifier = <別プロバイダ、e.g. Codex / Gemini>
- 別モデル投票で self-enhancement bias を回避 (F5 対策)
```

## 手順

### Step 1: 入力解析

- positional 引数を **やりたいこと** として受け取る
- オプションを parse
- 何も無ければ `--interactive` 扱いで「やりたいことは?」を 1 ターンだけ聞く

### Step 2: タスク特性を推定 (3 軸)

| 軸 | 判定 | デフォルト推定 |
|----|------|-------------|
| **A. 完了判定** | deterministic vs non-deterministic | テスト / コンパイル / git 系キーワード → deterministic、UI / 文章 / 仕様適合 → non-deterministic |
| **B. mission-critical 度** | high / mid / low | 賃料査定 / 認証 / 金融 → high (autonomy slider 0.2)、社内ダッシュボード / PoC → low (slider 0.7) |
| **C. 規模** | 1 file / 1 PR / repo 全体 | scope fence の粒度を決める (F8 対策) |

→ 不確実なら **Hybrid 質問** (Step 4)。

### Step 3: 7 要素 + F1-F10 対策を埋める

loop-engineering-autonomous-agents の 7 要素テンプレート + loop-failure-modes-mechanism-2026 の対策マトリクスを参照して埋める:

1. **End Goal** = 入力をそのまま (測定可能な形に書き直し)
2. **Termination** = max-budget / max-turns + 連続失敗回数 (default: 同一エラー hash 5 回 = F7 対策)
3. **Verification Gates** = 推定タスク特性に応じて Stage 1/2 を組む (4 章 Pattern A-D, llm-as-judge-bias-patterns)
4. **Feedback** = stderr 50 行を context 戻し
5. **State** = `.agent/progress.md` + `.agent/attempts.jsonl`
6. **Context Mgmt** = auto-compact + PreCompact / SessionStart 再注入 (F1)
7. **Error Handling** = git stash + 再試行禁止 (F2/F3)
8. **Cost Guard** = max-budget + tiering (F6) + cost check 5 ターン毎
9. (Non-deterministic 時) **Adversarial Verifier** = `--verifier` 指定または auto 推定 (F5)

### Step 4: Hybrid 質問 (default ON)

デフォルトで埋めた結果を一旦出力した後、以下を 1 ターンだけ聞く:

> 「以下のうち、調整したい箇所はありますか? (なければ 'OK' と回答してください)
> - End Goal の表現
> - Termination の閾値 (連続失敗回数 / max-turns)
> - Verification Gate の Stage 2 (決定的 gate) の中身
> - Cost guard の上限
> - その他 (自由記述)」

ユーザーが調整指示を出したら反映、`OK` なら確定。

### Step 5: 出力

最終 spec を **コード block 1 つ**で出力。末尾に**実行プリミティブの選択**を併記 (template.md「実行プリミティブ」表に従う):

- **Workflow ツール** (推奨: 多段 / 決定的 / adversarial) — spec の End Goal/Gates/Termination を Workflow script に転記。budget=cost guard(F6)、pipeline=gates、parallel+agentType=adversarial(F5)
- **`/loop`** (単一反復 / 定期) — `/loop /<cmd>` (self-paced) または `/loop <interval> /<cmd>` (定期)
- **`ralph-loop`** (A 型 rigid) — `/ralph-loop "<task>" --max-iterations N --completion-promise "<完了文>"`。旧 `--goal` の最近接代替
- **`claude -p`** — 1 ショット非対話

> `claude --goal` は廃止済みのため出力しない。

#### フェーズ束縛ルール (phase → primitive、claude-code-loop-harness-orchestration-2026)

タスクが複数フェーズ (research/diagnose/fix/verify/develop 等) を持つとき、**フェーズと7要素は直交**する (フェーズ=何を / 7要素=どう制御)。各フェーズの落とし先は公式決定ルールで決める:

| フェーズの性質 | 落とす先 |
|---|---|
| 複数フェーズが**文脈を共有** (plan→impl→test) / 反復改善が要る | **メイン会話** |
| **自己完結**・要約を返す・tool 制限したい | **subagent** (fresh isolated context) |
| 1会話で捌けない数 / **再実行可能に codify** | **Workflow** (script が loop/state を保持) |
| 再利用可能な手順を**メイン context で** | **skill** |

> ⚠️ **「フェーズごとに subagent を用意」をデフォルトにしない**。これは並列リサーチ fan-out には妥当だが、**coding loop のベストとしては一次ソースの裏が無い** (2026-06 deep research で refuted)。共有文脈の開発フェーズはメイン会話が公式の素直な答え。
> ⚠️ slash-command と skill は**統合済み** (`.claude/commands/foo.md` と `.claude/skills/foo/SKILL.md` は同義)。「subagent vs slash vs skill」でなく **invocation control + execution context** で選ぶ。
> 副作用フェーズ (`/commit` `/deploy`) は `disable-model-invocation: true` で人間ゲート化 (handoff ownership)。

### Step 6: ログ

- 生成した spec を `.agent/loop-design-history/YYYY-MM-DD-<slug>.md` に保存 (なければ作成)
- これで後から再利用 / 改善できる

## デフォルト推定の対応表

### タスクキーワード → タスクタイプ

| キーワード | type | verifier | mission-critical |
|----------|------|---------|----------------|
| テスト / test / pnpm test | deterministic | Haiku (Stage 1 で placeholder grep) | mid |
| コンパイル / tsc / build | deterministic | none (exit code のみ) | mid |
| migration / schema | deterministic | Codex (review) | **high** |
| UI / デザイン / Figma | non-deterministic | (人間 fallback 強推奨) | mid |
| ドキュメント / README | non-deterministic | Gemini (judge) | low |
| PR review / コードレビュー | hybrid | Codex (Pattern B) | mid |
| Inbox / ingest / PKM | deterministic | Haiku (Stage 1) | low |
| デプロイ / production / migration | deterministic | Codex + 人間 gate | **high** |
| バグ修正 / fix | deterministic | Haiku | mid |

### Verifier 推定ロジック

1. `--verifier` 指定があればそれ
2. mission-critical = **high** → Codex 推奨 (Pattern B = Anthropic × OpenAI 別プロバイダ)
3. 非 deterministic → Gemini or Codex 推奨
4. それ以外 → Haiku (legibility tax 原則、llm-as-judge-bias-patterns)

## F1-F10 対策フックの自動挿入

`--no-fail-hooks` が指定されない限り、以下を spec に自動挿入:

| Failure | 自動挿入する spec 行 |
|---------|-------------------|
| F1 Compaction 死スパイラル | "Context Management: auto-compact に任せ、`PreCompact` / `SessionStart`(source=compact) フックで CLAUDE.md と本 spec を再注入" (※ "PostCompact" は存在しないフック名) |
| F2 pipefail | "Error Handling: test 結果は file 経由 (`npm test > test.log 2>&1 ‖ true`)" |
| F3 MCP silent loss | "Error Handling: OAuth token は serialize 層に永続化、sanity check loop 内に" |
| F4 ロール配列破壊 | "公式 SDK (Claude Agent SDK) に寄せる、抽象化レイヤーを薄く" |
| F5 placeholder sneak | "Verification Gate Stage 1: placeholder grep (`TODO ‖ return true ‖ ;\\s*$`) 検出で reject" |
| F6 コスト暴走 | "Cost Guard: /cost を 5 ターン毎に check、超過で停止" |
| F7 無限ループ | "Termination: 同一エラー hash 5 回 → escalate" |
| F8 scope 暴走 | "Constraints: 1 ループの scope を 1 file / 1 function に fence" |
| F9 偽合言葉 | "Verification: 完了報告は output で証明 (file 内容 grep / git diff)" |
| F10 cache 破壊 | "Context Management: 動的タイムスタンプ / ツール順ランダム化を避ける" |

## 例

### 例 1: `/loop-design "テストが通るまで src/ を直す"`

→ 推定: deterministic / mid critical / 1 PR 規模 / verifier=Haiku
→ Hybrid 質問で「max-turns 30 で OK ?」を聞く
→ 確定後、spec 出力 + 実行プリミティブ選択 (deterministic なら Workflow か `/loop`)

### 例 2: `/loop-design "Inbox の processed:false を 5 件 Card 化" --max-budget=2`

→ 推定: deterministic / low critical / repo 全体 / verifier=Haiku
→ Stage 2 決定的 gate = `grep "processed: false" Inbox/*.md | wc -l ≤ 旧値-5`
→ State = Inbox の frontmatter を直接 mutate するため git diff で track

### 例 3: `/loop-design "ホーム画面の hero セクションを改善" --type=non-deterministic`

→ 推定: non-deterministic / mid critical / 1 file / verifier=Codex (adversarial)
→ Stage 1 = Codex に「視認性 / アクセシビリティ / ブランド整合」3 観点でレビュー依頼
→ 「人間 gate 必須」を spec 末尾に強調表示

## Related (Cards)

- loop-engineering-autonomous-agents — 7 要素の理論背景
- claude-code-loop-harness-orchestration-2026 — フェーズ→プリミティブ対応、ネスト上限、per-phase subagent の注意点 (本 skill の実行プリミティブ選択の根拠)
- loop-failure-modes-mechanism-2026 — F1-F10 対策の出典
- llm-as-judge-bias-patterns — verifier 設計の根拠
- anthropic-pricing-and-tiering-2026 — cost guard / tiering
- karpathy-autonomy-slider — mission-critical 度の autonomy slider
- loop-engineering-intro-guide-jp — 入門ガイド (本 skill の使い方を理解する前提)

## 注意事項

- 本 skill は **spec を生成するだけ**。生成された spec は **人間が必ず目視 review** してから実行する (F9 偽合言葉完了の連鎖を防ぐため)
- `--no-fail-hooks` は意図して F1-F10 対策を外すときのみ使う (例: 既存 spec の minimal 化、教育目的の素朴版生成)
- 実行プリミティブは Claude Code 2.1.185 時点で確認: `Workflow` ツール / `/loop` skill / `ralph-loop` plugin / `claude -p`。**旧 `claude --goal` / `--max-iterations` は存在しない** (誤って出力しないこと)
- secret は spec に直書きしない (`op://` 経由を強制)
- 生成した spec を **そのまま social に公開しない** (内部のディレクトリ構造 / 業務情報が漏れる可能性)
