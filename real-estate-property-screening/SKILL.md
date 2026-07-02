---
name: real-estate-property-screening
description: "Real estate property screening: scan Gmail for maisoku (物件紹介) emails, score against 5 investment patterns (A=旅館業, B=節税, C=区分OC, D1=法人築浅, D2=法人築古RC), fetch Airbnb ADR for innkeeping candidates, and append results to Google Sheets."
version: 1.0.0
platforms: [macos]
tags: [real-estate, property, gmail, airbnb, google-sheets, japan, maisoku, screening]
---

# Real Estate Property Screening（物件スクリーニング）

Gmail に届く不動産業者からのメールを自動スキャンし、5つの投資パターンでスコアリング、
旅館業候補物件には Airbnb ADR を取得してDiscordに通知、Google Sheetsに自動追記するスクリプト。

## Required Environment Variables

```bash
export KENBIYA_EMAIL="your@email.com"          # 健美家ログインメールアドレス
export KENBIYA_PASSWORD="yourpassword"          # 健美家ログインパスワード
export SCREENING_SPREADSHEET_ID="1abc..."       # Google Sheets スプレッドシートID
export GMAIL_ADDRESS="your@gmail.com"           # GmailアカウントID（authuser用）
export AIRBNB_API_KEY="d306....."               # Airbnb GraphQL APIキー
export HERMES_VENV_PYTHON="/path/to/.venv/bin/python"  # hermes-agentのvenv Python（省略可）
```

`AIRBNB_API_KEY` の再取得方法 → `maisoku-analysis` スキルの `references/airbnb-market-research.md`

## Usage

```bash
# 通常実行（直近1日のメールをスキャン）
python3.11 scripts/property_screening.py

# 直近2日分
python3.11 ... --days 2

# Discord送信しない（stdout出力のみ、テスト用）
python3.11 ... --dry-run

# 処理済みメールも再処理
python3.11 ... --force
```

## Cron Setup

```bash
# 毎日 06:00/13:00/19:00 JST (= UTC 21:00/04:00/10:00)
# hermes cron で以下のスクリプトを設定:
# python3.11 scripts/property_screening.py
```

## Investment Patterns (5パターン)

| # | パターン | 物件種別 | 条件 |
|---|---------|---------|------|
| **A** | 旅館業・民泊 | 用途地域OK×駅近 | 商業/近隣商業/準工業/住居系 + 徒歩10分以内 |
| **B** | 個人節税(築古) | 木造・鉄骨 築20年+ | 減価償却 |
| **C** | 区分OC・キャピタル | 区分マンション | 5年売却・キャピタルゲイン狙い |
| **D1** | 法人 新築・築浅RC | RC/SRC 築15年以内 | 収益安定 |
| **D2** | 法人 築古RC | RC 築25年+ | 収益+節税 |

## Google Sheets Column Layout

物件一覧シートの列定義:
- A: 受信日, B: 業者名, C: 物件名/件名, D: 所在地, E: 最寄り駅
- F: 徒歩(分), G: 価格(万), H: 利回り(%), I: 構造, J: 築年数
- K: 戸数, L: 用途地域, M: パターン, N: スコア, O: ステータス
- P: メモ, Q: Gmailリンク, R: ADR一棟(円/泊), S: ADR稼働日数, T: ADR月収(万)

## Customization

### SOURCE_TRUST（業者信頼度）

`scripts/property_screening.py` の `SOURCE_TRUST` 辞書に業者ドメインを追加:
```python
SOURCE_TRUST = {
    "kenbiya.com": {"name": "健美家", "trust": 85, "structured": True},
    # 追加例:
    "your-agency.co.jp": {"name": "〇〇不動産", "trust": 75, "structured": False},
}
```

### SKIP_SUBJECTS（除外キーワード）

取引中・管理系メールの件名キーワードをリストに追加して除外。

### スコア閾値

`format_report()` 内の `THRESHOLD = 40` を変更してヒット感度調整。
健美家詳細取得閾値: `KB_DETAIL_THRESHOLD = 50`。

## Pitfalls

- **Gmail OR検索タイムアウト**: 複合OR検索は45秒超でタイムアウト → 単一キーワードを複数クエリに分割
- **PyMuPDF**: `python3` では動かないことがある → `python3.11` を明示
- **健美家 Cookie**: `/tmp/kb_cookies.txt` が3時間超で無効 → 自動再ログイン実装済み
- **健美家 クラウドIP**: Browserbase等はブロック → macOS上のcurlで実行
- **Airbnb ADR処理順序**: NG判定（健美家詳細取得）の**後**にADR取得すること。順序を逆にすると除外物件でもADR APIを叩き実行時間が大幅増加
- **駅名バリデーション**: 記号入り・異常に長い・日本語なしの駅名はAPIを叩かない（バリデーション実装済み）
- **転貸案件**: 賃料のみで売価・利回りなしのメールは売買スコアと混在させず `rental_entries` に分離
- **シェアハウス除外**: 専有面積<10m²または「シェアハウス」キーワードで除外。「民泊専用」「旅館業」は**除外しない**（投資対象）
- **スプシ venv**: `googleapiclient` はhermes-agentのvenvにのみインストール → `HERMES_VENV_PYTHON` から site-packages を `sys.path` に追加
- **Gmailリンク形式**: `https://mail.google.com/mail/#inbox/{msg_id}?authuser={GMAIL_ADDRESS}` が最も安定（u/0 等のアカウント番号依存はNG）

## Script

メインスクリプトは `scripts/property_screening.py` に格納。
