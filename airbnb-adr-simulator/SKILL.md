---
name: airbnb-adr-simulator
description: "Fetch Airbnb income estimate (ADR, occupancy, monthly revenue) for any area using the official Airbnb GraphQL API — the same data the Airbnb host simulator shows. Input: station/area name. Output: per-night rate, avg nights, monthly estimate for entire_home and private_room."
version: 1.0.0
platforms: [macos, linux]
tags: [airbnb, real-estate, adr, innkeeping, minpaku, income-estimate, graphql]
---

# Airbnb ADR Simulator

Airbnb 公式ホストシミュレーターと同じデータを GraphQL API で取得する。
エリア名（駅名など）を入力すると、一棟貸し・一室貸しの ADR・稼働日数・月収試算を返す。

## Setup

環境変数:
```bash
export AIRBNB_API_KEY="d306zoyjsyarp7ifhu67rjxn52tv0t20"
```

APIキーの再取得方法: Airbnb サイトのJSバンドルから `X-Airbnb-API-Key` を抽出。
詳細: `maisoku-analysis` スキルの `references/airbnb-market-research.md`

## Usage

```bash
python3 ~/.hermes/skills/airbnb-adr-simulator/scripts/airbnb_adr.py "すすきの駅"
python3 ~/.hermes/skills/airbnb-adr-simulator/scripts/airbnb_adr.py "渋谷駅"
python3 ~/.hermes/skills/airbnb-adr-simulator/scripts/airbnb_adr.py "すすきの, 札幌市"
```

出力例:
```
📍 すすきの駅 → すすきの, 札幌市中央区...
🏨 一棟貸し (ENTIRE_HOME / 1BD / 4名)
   単価:   ¥25,261/泊
   稼働:   24泊/月 (80%)
   月収:   ¥606,262
   距離:   ✅ 0.1km

🛏 一室貸し (PRIVATE_ROOM / 1BD / 2名)
   単価:   ¥10,363/泊
   稼働:   15泊/月 (50%)
   月収:   ¥155,452
   距離:   ✅ 0.2km
```

## API Details

- **Endpoint**: `POST https://www.airbnb.jp/api/v3/GetHostEstimateData`
- **API Key header**: `X-Airbnb-API-Key: <key>`
- **Operation**: `GetHostEstimateData` (persisted query)
- **Hash**: `a929d4d832695d0dc9344afb283387ecc8140f6e58b5a1949051898afe6e1167`
- **location 型**: `{"searchQuery": "エリア名"}` ← `{"query": ...}` ではない
- **durationGranularity**: `["MONTHLY"]` 必須

room_type は `ENTIRE_HOME`（一棟）と `PRIVATE_ROOM`（一室）を別クエリで取得する。

## Distance Verification

Nominatim で駅座標を取得し、API が返すリスト物件の重心との距離を計算。
エリアのサジェストがズレていないか確認するためのバリデーション。

- ✅ 1km以内 — 精度高
- 🟡 1〜3km — 要注意
- ⚠️ 3km超 — エリア名を変えて再試行

## Pitfalls

- **location 入力が超敏感**: `"すすきの, 札幌市"` と `"札幌市 すすきの"` は別エリアに解釈される。駅名単体（`"すすきの駅"`）が最も精度が高い
- **Nominatim レートリミット**: 連続呼び出しは 1 秒以上間隔を空ける
- **稼働日数は `sections[2].value`**: API レスポンスの `header.sections[2]` がエリア実績の平均稼働泊数（自前で仮定しない）
- **月収は `earningsEstimateListNative[avg_nights - 1]`**: スライダーのインデックスと対応

## Script

`scripts/airbnb_adr.py` — スタンドアロンで動く CLI スクリプト。
