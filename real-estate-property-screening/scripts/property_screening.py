#!/usr/bin/env python3.11
"""
Real Estate Property Screening Script v2
Scan Gmail for maisoku (物件紹介) emails, score against 5 investment patterns,
fetch Airbnb ADR for innkeeping candidates, and append results to Google Sheets.

Required environment variables:
    KENBIYA_EMAIL            - 健美家 login email
    KENBIYA_PASSWORD         - 健美家 login password
    SCREENING_SPREADSHEET_ID - Google Sheets spreadsheet ID
    GMAIL_ADDRESS            - Gmail account address (for authuser link)
    AIRBNB_API_KEY           - Airbnb GraphQL API key
    HERMES_VENV_PYTHON       - (optional) path to hermes-agent venv Python

Usage:
    python3.11 property_screening.py          # scan last 1 day
    python3.11 property_screening.py --days 2 # scan last 2 days
    python3.11 property_screening.py --dry-run # stdout only, no Discord/Sheets write
    python3.11 property_screening.py --force   # reprocess already-seen emails
"""

import sys, os, json, re, datetime, subprocess, argparse, time
from pathlib import Path
from collections import defaultdict

# ─────────────────────────────────────────────
# Configuration (from environment variables)
# ─────────────────────────────────────────────
KB_USER    = os.environ.get("KENBIYA_EMAIL", "")
KB_PASS    = os.environ.get("KENBIYA_PASSWORD", "")
GMAIL_ADDR = os.environ.get("GMAIL_ADDRESS", "")
SPREADSHEET_ID = os.environ.get("SCREENING_SPREADSHEET_ID", "")
AIRBNB_API_KEY = os.environ.get("AIRBNB_API_KEY", "")
AIRBNB_GQL_HASH = os.environ.get("AIRBNB_GQL_HASH", "")
# Get hash from DevTools → Network → GetHostEstimateData → Payload → extensions.persistedQuery.sha256Hash

# hermes-agent venv Python path (for googleapiclient)
VENV_PY_PATH = os.environ.get(
    "HERMES_VENV_PYTHON",
    str(Path.home() / "Code/hermes-agent/.venv/bin/python")
)

PROCESSED_DB = Path.home() / ".hermes" / "maisoku_processed.json"
GAPI = os.environ.get(
    "GOOGLE_API_SCRIPT",
    # Default: Claude Code (hermes) google-workspace skill path
    # Set GOOGLE_API_SCRIPT to your own google_api.py path if different
    str(Path.home() / ".hermes/skills/productivity/google-workspace/scripts/google_api.py")
)
CACHE_DIR    = Path("/tmp/property_screening")
CACHE_DIR.mkdir(exist_ok=True)
KB_COOKIE    = Path("/tmp/kb_cookies.txt")

# Score threshold for Kenbiya detail fetch
KB_DETAIL_THRESHOLD = 50

# Gmail scan queries (split to avoid OR-query timeout)
SCAN_QUERIES = [
    "利回り newer_than:{days}d",
    "収益物件 newer_than:{days}d",
    "民泊 OR 旅館業 newer_than:{days}d",
]

# Skip keywords in subject (transaction/management emails)
SKIP_SUBJECTS = [
    "ウィンベルソロ", "LPガス", "火災保険", "管理会社変更",
    "決済", "通知書", "追加資料", "返済", "確定申告", "領収書",
    "司法書士", "登記", "固定資産税", "清算", "融資審査", "金消",
    "保証", "保険証", "修繕積立", "管理費", "滞納", "退去",
    "入居者", "賃貸借", "更新", "解約", "敷金", "礼金",
]

# Skip property types (not suitable for investment/financing)
SKIP_PROPERTY_TYPES = [
    "シェアハウス", "シェア ハウス", "ゲストハウス",
    # NOTE: "旅館" and "民泊専用" are NOT excluded — they are investment targets
    "ホテル",  # Existing hotel operations only
    "サービス付き高齢者", "サ高住", "老人ホーム",
    "グループホーム", "障がい者", "障害者", "就労支援",
]

# Skip patterns (ads, seminars, etc.)
SKIP_PATTERNS = [
    r'号外', r'PR$', r'セミナー', r'ウェビナー', r'メルマガ',
    r'ランキング', r'コラム', r'特集', r'会員向け',
]

# Source trust scores by domain
SOURCE_TRUST = {
    # Portals (structured data in subject)
    "kenbiya.com":        {"name": "健美家",       "trust": 85, "structured": True},
    "rakumachi.jp":       {"name": "楽待",          "trust": 85, "structured": True},
    "suumo.jp":           {"name": "SUUMO",         "trust": 80, "structured": True},
    "nifty.com":          {"name": "ニフティ",      "trust": 80, "structured": True},
    "athome.co.jp":       {"name": "アットホーム",  "trust": 80, "structured": True},
    # Direct agencies (customize for your relationships)
    "canary-app.com":     {"name": "信託ホーム",    "trust": 90, "structured": False},
    "ad-home.co.jp":      {"name": "アドバンスホーム", "trust": 80, "structured": False},
    "ta-japan.com":       {"name": "スリーアローズ", "trust": 70, "structured": False},
    # Add more agencies as needed:
    # "your-agency.co.jp": {"name": "〇〇不動産", "trust": 70, "structured": False},
}

# Investment patterns
PATTERNS = {
    "A": {
        "name": "旅館業・民泊",
        "emoji": "🏨",
        "banks": ["滋賀銀(セゾン保証型)", "セゾンFD"],
        "zoning_ok": ["商業", "近隣商業", "準工業", "1種住居", "2種住居", "準住居",
                      "商業地域", "近隣商業地域", "準工業地域",
                      "第1種住居", "第2種住居", "準住居地域"],
        "zoning_ng": ["低層", "中高層", "工業専用", "田園住居"],
        "max_walk": 10,
        "walk_only": True,   # No bus
    },
    "B": {
        "name": "個人節税(築古)",
        "emoji": "🏗",
        "banks": ["滋賀銀", "静銀", "auじぶん"],
        "structures": ["木造", "鉄骨", "軽量鉄骨", "S造", "W造", "LS造"],
        "min_age": 20,
    },
    "C": {
        "name": "区分OC・キャピタル",
        "emoji": "🏢",
        "banks": ["滋賀銀", "SMBC信託", "イオン", "オリックス", "ジャックス"],
        "types": ["区分", "マンション", "区分マンション"],
        "max_price": 8000,   # 万円
    },
    "D1": {
        "name": "法人 新築・築浅RC",
        "emoji": "🏛",
        "banks": ["オリックス", "スルガ", "千葉銀", "横浜銀", "神奈川銀"],
        "structures": ["RC", "鉄筋コンクリート", "SRC", "鉄骨鉄筋"],
        "max_age": 15,
    },
    "D2": {
        "name": "法人 築古RC",
        "emoji": "🏚",
        "banks": ["日本保証/東和銀", "山陰合同銀"],
        "structures": ["RC", "鉄筋コンクリート", "SRC"],
        "min_age": 25,
    },
}

# ─────────────────────────────────────────────
# Processed email DB
# ─────────────────────────────────────────────
def load_processed():
    if PROCESSED_DB.exists():
        return set(json.loads(PROCESSED_DB.read_text()).get("emails", []))
    return set()

def save_processed(processed_set):
    PROCESSED_DB.parent.mkdir(exist_ok=True)
    existing = {}
    if PROCESSED_DB.exists():
        existing = json.loads(PROCESSED_DB.read_text())
    existing["emails"] = list(processed_set)
    PROCESSED_DB.write_text(json.dumps(existing, ensure_ascii=False, indent=2))

# ─────────────────────────────────────────────
# Gmail
# ─────────────────────────────────────────────
def search_emails(query, max_results=50):
    cmd = f'{GAPI} gmail search "{query}" --max {max_results} 2>/dev/null'
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=60)
    try:
        return json.loads(r.stdout)
    except Exception:
        return []

# ─────────────────────────────────────────────
# Sender parsing
# ─────────────────────────────────────────────
def parse_sender(from_str):
    """Parse sender email/domain/trust from 'From' header string."""
    m = re.search(r'<([^>]+)>', from_str)
    email = m.group(1) if m else from_str
    domain = email.split("@")[-1].lower() if "@" in email else ""

    name_m = re.match(r'"?([^"<]+)"?\s*<', from_str)
    sender_name = name_m.group(1).strip() if name_m else from_str

    trust_info = SOURCE_TRUST.get(domain, {
        "name": sender_name, "trust": 60, "structured": False
    })
    return {
        "email": email,
        "domain": domain,
        "sender_name": sender_name,
        "display_name": trust_info["name"],
        "trust": trust_info["trust"],
        "structured": trust_info["structured"],
    }

# ─────────────────────────────────────────────
# Property info parsing (subject + snippet)
# ─────────────────────────────────────────────
def parse_property(subject, snippet, sender_info):
    """
    Extract property info from subject and snippet.
    Portals (kenbiya, rakumachi) have structured subjects → high accuracy.
    """
    text = subject + " " + snippet
    prop = {}

    # Price: "1億4,000万円" / "3,680万円" / "3億"
    m = re.search(r'(\d+)億\s*(\d+(?:,\d+)?)?万?円?', text)
    if m:
        oku = int(m.group(1))
        man = int(m.group(2).replace(",", "")) if m.group(2) else 0
        prop["price_man"] = oku * 10000 + man
    else:
        m = re.search(r'(\d+(?:,\d+)?)万円', text)
        if m:
            prop["price_man"] = int(m.group(1).replace(",", ""))

    # Yield
    m = re.search(r'利回り[：:\s]*([\d.]+)\s*%?|(\d+\.\d+)％', text)
    if m:
        prop["yield_pct"] = float(m.group(1) or m.group(2))

    # Station & walk minutes
    m = re.search(r'([^\s　]{2,10}駅)\s*(?:徒歩\s*(\d+)\s*分|バス\s*\d+分\s*徒歩\s*(\d+)分)?', text)
    if m:
        prop["station"] = m.group(1)
        if m.group(2):
            prop["walk_min"] = int(m.group(2))
            prop["transport"] = "徒歩"
        elif m.group(3):
            prop["walk_min"] = int(m.group(3))
            prop["transport"] = "バス+徒歩"
    if "walk_min" not in prop:
        m2 = re.search(r'([^\s　]{2,10}駅)\s*バス\s*(\d+)\s*分', text)
        if m2:
            prop["station"] = m2.group(1)
            prop["walk_min"] = 99  # Bus → NG
            prop["transport"] = "バス"

    # Structure
    for struct, pattern in [
        ("RC",   r'\bRC\b|鉄筋コンクリート|ＲＣ'),
        ("SRC",  r'\bSRC\b|鉄骨鉄筋'),
        ("S造",  r'\bS造\b|鉄骨造|鉄骨2|鉄骨3'),
        ("木造", r'木造'),
        ("軽量鉄骨", r'軽量鉄骨|LS造'),
    ]:
        if re.search(pattern, text):
            prop["structure"] = struct
            break

    # Age (years old)
    m = re.search(r'築(\d+)年', text)
    if m:
        prop["age"] = int(m.group(1))
    else:
        m = re.search(r'(\d{4})年(?:\d+月)?築|築年月[：:]\s*(\d{4})年', text)
        if m:
            year = int(m.group(1) or m.group(2))
            prop["age"] = datetime.date.today().year - year

    # Property type
    if re.search(r'区分|分譲', text):
        prop["type"] = "区分"
    elif re.search(r'一棟売りマンション|一棟マンション', text):
        prop["type"] = "一棟マンション"
    elif re.search(r'一棟売りアパート|一棟アパート|アパート', text):
        prop["type"] = "一棟アパート"
    elif re.search(r'戸建|一戸建', text):
        prop["type"] = "戸建"
    elif re.search(r'土地', text):
        prop["type"] = "土地"

    # Address
    m = re.search(r'(北海道|東京都|大阪府|京都府|神奈川県|埼玉県|千葉県|愛知県|福岡県|.{2,3}[県])[^\s　]{2,20}[市区町村]', text)
    if m:
        prop["address"] = m.group(0)

    # Zoning (if explicitly stated)
    for zone in ["商業地域", "近隣商業地域", "準工業地域", "第1種住居地域", "第2種住居地域",
                 "準住居地域", "第1種低層", "第2種低層", "工業専用"]:
        if zone in text:
            prop["zoning"] = zone
            break

    prop["title"] = subject[:80]
    prop["source_trust"] = sender_info["trust"]
    prop["source_structured"] = sender_info["structured"]

    # Rental detection (賃料あり + 売価・利回りなし → 転貸案件)
    m_rent = re.search(r'賃料[：:\s]*約?([\d,]+)万円|月額[：:\s]*約?([\d,]+)万円', text)
    if m_rent:
        rent_str = m_rent.group(1) or m_rent.group(2) or "0"
        prop["rent_man"] = int(rent_str.replace(",", ""))
        if not prop.get("yield_pct") and not prop.get("price_man"):
            prop["is_rental"] = True

    return prop if len(prop) > 2 else None

# ─────────────────────────────────────────────
# Scoring
# ─────────────────────────────────────────────
def score_property(prop, sender_info):
    if not prop:
        return {}

    zoning    = prop.get("zoning", "") or ""
    walk      = prop.get("walk_min")
    transport = prop.get("transport", "") or ""
    structure = prop.get("structure", "") or ""
    age       = prop.get("age")
    ptype     = prop.get("type", "") or ""
    price     = prop.get("price_man")
    yld       = prop.get("yield_pct")
    trust     = sender_info["trust"]
    title     = prop.get("title", "") or ""

    results = {}

    # ── Pattern A: 旅館業・民泊 ──
    a = 0; ar = []
    pat = PATTERNS["A"]

    # Bonus if innkeeping keywords explicitly in subject
    minpaku_keywords = ["民泊", "旅館業", "新法民泊", "住宅宿泊", "Airbnb", "airbnb", "民泊向け"]
    if any(kw in title for kw in minpaku_keywords):
        a += 15; ar.append("民泊/旅館業向け明記✅")

    if zoning:
        if any(z in zoning for z in pat["zoning_ok"]) and not any(z in zoning for z in pat["zoning_ng"]):
            a += 40; ar.append(f"用途地域OK({zoning})")
        elif any(z in zoning for z in pat["zoning_ng"]):
            ar.append(f"用途地域NG({zoning})")
        else:
            ar.append(f"用途地域要確認({zoning})")
    else:
        a += 10; ar.append("用途地域未記載")

    if walk is not None:
        if transport != "バス" and walk <= pat["max_walk"]:
            a += 35; ar.append(f"駅徒歩{walk}分✅")
        elif walk <= 5:
            a += 35; ar.append(f"駅徒歩{walk}分✅")
        else:
            ar.append(f"駅{walk}分({transport or '徒歩'})")
    else:
        a += 10; ar.append("駅距離未記載")

    if yld and yld >= 7: a += 15; ar.append(f"利回り{yld}%")
    a += int(trust * 0.1)
    results["A"] = {"score": min(a, 100), "reasons": ar}

    # ── Pattern B: 個人節税(築古) ──
    b = 0; br = []
    pat = PATTERNS["B"]
    if any(s in structure for s in pat["structures"]):
        b += 35; br.append(f"構造OK({structure})")
    else:
        br.append(f"構造({structure or '未記載'})")

    if age is not None:
        if age >= 30:   b += 40; br.append(f"築{age}年(残存ほぼゼロ)")
        elif age >= 22: b += 30; br.append(f"築{age}年(節税効果大)")
        elif age >= 15: b += 15; br.append(f"築{age}年(節税効果中)")
        else:           br.append(f"築{age}年(節税効果小)")
    else:
        b += 8; br.append("築年数未記載")

    if price and price < 15000: b += 15; br.append(f"{price:,}万")
    if yld and yld >= 8: b += 10; br.append(f"利回り{yld}%")
    b += int(trust * 0.05)
    results["B"] = {"score": min(b, 100), "reasons": br}

    # ── Pattern C: 区分OC ──
    c = 0; cr = []
    pat = PATTERNS["C"]
    if any(t in ptype for t in pat["types"]):
        c += 55; cr.append("区分物件✅")
    else:
        cr.append(f"({ptype or '一棟/その他'})")

    if price:
        if price <= pat["max_price"]: c += 25; cr.append(f"{price:,}万(OC帯)")
        else: cr.append(f"{price:,}万(高額)")
    if yld and yld >= 5: c += 15; cr.append(f"利回り{yld}%")
    c += int(trust * 0.05)
    results["C"] = {"score": min(c, 100), "reasons": cr}

    # ── Pattern D1: 法人新築・築浅 ──
    d1 = 0; d1r = []
    pat = PATTERNS["D1"]
    if any(s in structure for s in pat["structures"]):
        d1 += 35; d1r.append("RC/SRC✅")
    else:
        d1r.append(f"構造({structure or '未記載'})")

    if age is not None:
        if age <= 5:    d1 += 45; d1r.append(f"築{age}年(新築)✅")
        elif age <= 10: d1 += 35; d1r.append(f"築{age}年(築浅)✅")
        elif age <= 15: d1 += 20; d1r.append(f"築{age}年")
        else:           d1r.append(f"築{age}年(D2候補)")
    else:
        d1 += 8; d1r.append("築年数未記載")

    if yld and yld >= 6: d1 += 20; d1r.append(f"利回り{yld}%")
    d1 += int(trust * 0.05)
    results["D1"] = {"score": min(d1, 100), "reasons": d1r}

    # ── Pattern D2: 法人築古RC ──
    d2 = 0; d2r = []
    pat = PATTERNS["D2"]
    if any(s in structure for s in pat["structures"]):
        d2 += 35; d2r.append("RC構造✅")
    else:
        d2r.append(f"構造({structure or '未記載'})")

    if age is not None:
        if age >= 35:   d2 += 45; d2r.append(f"築{age}年(築古RC対象)✅")
        elif age >= 25: d2 += 30; d2r.append(f"築{age}年(築古RC)")
        else:           d2r.append(f"築{age}年")
    else:
        d2 += 8; d2r.append("築年数未記載")

    if yld and yld >= 7: d2 += 20; d2r.append(f"利回り{yld}%")
    d2 += int(trust * 0.05)
    results["D2"] = {"score": min(d2, 100), "reasons": d2r}

    return results

# ─────────────────────────────────────────────
# Report formatting
# ─────────────────────────────────────────────
def format_report(all_entries, date_str, days, rental_entries=None):
    rental_entries = rental_entries or []
    if not all_entries and not rental_entries:
        return (
            f"🏠 **物件スクリーニング {date_str}**（直近{days}日）\n"
            f"新着物件メールなし（スキャン0件）"
        )

    THRESHOLD = 40  # Hit threshold

    pat_hits = defaultdict(list)
    no_hit = []
    for e in all_entries:
        scores = e["scores"]
        if not scores:
            continue
        best_key, best_val = max(scores.items(), key=lambda x: x[1]["score"])
        if best_val["score"] >= THRESHOLD:
            pat_hits[best_key].append({**e, "best_score": best_val["score"], "best_reasons": best_val["reasons"]})
        else:
            no_hit.append(e)

    total_hit = sum(len(v) for v in pat_hits.values())
    total_scan = len(all_entries)

    lines = [
        f"🏠 **物件スクリーニング {date_str}**（直近{days}日）",
        "━" * 32,
        f"📊 スキャン {total_scan}件 → **ヒット {total_hit}件**",
        "",
    ]

    for pk in ["A", "B", "C", "D1", "D2"]:
        pat  = PATTERNS[pk]
        hits = sorted(pat_hits.get(pk, []), key=lambda x: x["best_score"], reverse=True)

        if not hits:
            lines.append(f"{pat['emoji']} **[{pk}] {pat['name']}** — 該当なし")
            continue

        lines.append(f"{pat['emoji']} **[{pk}] {pat['name']}** — {len(hits)}件")
        lines.append(f"　💳 {' / '.join(pat['banks'])}")

        for h in hits[:5]:  # Top 5
            p  = h["prop"]
            si = h["sender"]
            lines.append("")
            score_bar = "█" * (h["best_score"] // 20) + "░" * (5 - h["best_score"] // 20)
            lines.append(f"　✅ **{p.get('title','?')[:60]}**")
            lines.append(f"　　スコア {h['best_score']}/100 [{score_bar}]　信頼度:{si['trust']} ({si['display_name']})")

            info_parts = []
            if p.get("address"):        info_parts.append(f"📍 {p['address']}")
            if p.get("station"):
                walk_str = f" 徒歩{p['walk_min']}分" if p.get("walk_min") and p.get("walk_min") < 90 else ""
                transport_str = f"({p['transport']})" if p.get("transport") == "バス+徒歩" else ""
                info_parts.append(f"🚉 {p['station']}{walk_str}{transport_str}")
            if p.get("zoning"):         info_parts.append(f"🏗 {p['zoning']}")

            nums = []
            if p.get("price_man"):  nums.append(f"{p['price_man']:,}万円")
            if p.get("yield_pct"): nums.append(f"利回り{p['yield_pct']}%")
            if p.get("structure"): nums.append(p["structure"])
            if p.get("age"): nums.append(f"築{p['age']}年")
            if p.get("type"):      nums.append(p["type"])
            if nums: info_parts.append(f"💰 {' / '.join(nums)}")

            for part in info_parts:
                lines.append(f"　　{part}")

            lines.append(f"　　📌 {' / '.join(h['best_reasons'][:3])}")
            link_display = h.get("link", "")
            if not link_display and h.get("msg_id"):
                link_display = f"https://mail.google.com/mail/#inbox/{h['msg_id']}?authuser={GMAIL_ADDR}"

            # Pattern A: Show Airbnb ADR
            if pk == "A" and h.get("adr"):
                adr = h["adr"]
                if adr.get("error"):
                    lines.append(f"　　🏨 ADR取得失敗: {adr['error']}")
                else:
                    entire  = adr.get("entire")
                    private = adr.get("private")
                    if entire and not entire.get("error"):
                        lines.append(
                            f"　　🏨 一棟: ¥{entire['per_night']:,}/泊 × {entire['avg_nights']}泊({entire['occ_pct']}%) "
                            f"= **¥{entire['monthly_est']:,}/月** {entire['confidence']}"
                        )
                    if private and not private.get("error"):
                        lines.append(
                            f"　　🛏 一室: ¥{private['per_night']:,}/泊 × {private['avg_nights']}泊({private['occ_pct']}%) "
                            f"= ¥{private['monthly_est']:,}/月 {private['confidence']}"
                        )
            lines.append(f"　　🔗 {link_display}")

        if len(hits) > 5:
            lines.append(f"　　…他 {len(hits)-5}件")
        lines.append("")

    # Rental (転貸) section
    if rental_entries:
        lines.append("━" * 32)
        lines.append(f"🏠 **[転貸] 民泊・旅館業運営案件** — {len(rental_entries)}件")
        lines.append("　※売買ではなく転貸。賃料が固定費用、売上-賃料=粗利で評価")
        for h in rental_entries:
            p  = h["prop"]
            si = h["sender"]
            lines.append("")
            lines.append(f"　📌 **{p.get('title','?')[:60]}**")
            lines.append(f"　　{si['display_name']}")
            info_parts = []
            if p.get("address"):  info_parts.append(f"📍 {p['address']}")
            if p.get("station"):
                walk_str = f" 徒歩{p['walk_min']}分" if p.get("walk_min") and p.get("walk_min") < 90 else ""
                info_parts.append(f"🚉 {p['station']}{walk_str}")
            if p.get("zoning"):   info_parts.append(f"🏗 {p['zoning']}")
            if p.get("type"):     info_parts.append(f"🏘 {p['type']}")
            for part in info_parts:
                lines.append(f"　　{part}")
            rent = p.get("rent_man", 0)
            if rent:
                lines.append(f"　　💴 賃料: {rent}万円/月（固定費）")
            adr = h.get("adr")
            if adr and not adr.get("error"):
                en = adr.get("entire")
                if en and not en.get("error"):
                    gross = en["monthly_est"]
                    net   = gross - rent * 10000
                    net_str = f"**¥{net:,}/月**" if net > 0 else f"⚠️¥{net:,}/月(赤字)"
                    lines.append(
                        f"　　🏨 売上試算: ¥{gross:,}/月 - 賃料{rent}万 = {net_str} {en['confidence']}"
                    )
            link_display = h.get("link", "")
            if not link_display and h.get("msg_id"):
                link_display = f"https://mail.google.com/mail/#inbox/{h['msg_id']}?authuser={GMAIL_ADDR}"
            lines.append(f"　　🔗 {link_display}")
        lines.append("")

    # Agency summary
    lines.append("━" * 32)
    lines.append("📋 **業者別ヒット数**")
    sender_hit_cnt = defaultdict(int)
    for pk, hits in pat_hits.items():
        for h in hits:
            sender_hit_cnt[h["sender"]["display_name"]] += 1
    for sname, cnt in sorted(sender_hit_cnt.items(), key=lambda x: -x[1]):
        lines.append(f"　• {sname}: {cnt}件")

    if no_hit:
        lines.append(f"\n💤 閾値未満: {len(no_hit)}件")

    return "\n".join(lines)

# ─────────────────────────────────────────────
# Airbnb ADR Simulator
# ─────────────────────────────────────────────
def _haversine_km(lat1, lon1, lat2, lon2):
    import math
    R = 6371
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = math.sin(dlat/2)**2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlon/2)**2
    return R * 2 * math.asin(math.sqrt(a))

def _geocode_station(station_name):
    """Station name → (lat, lon, display). Uses Nominatim."""
    from urllib.parse import quote
    r = subprocess.run([
        'curl', '-s',
        f'https://nominatim.openstreetmap.org/search?q={quote(station_name)}&format=json&limit=1&accept-language=ja',
        '-H', 'User-Agent: property-screening/2.0'
    ], capture_output=True, text=True, timeout=10)
    try:
        results = json.loads(r.stdout)
        if results:
            return float(results[0]['lat']), float(results[0]['lon']), results[0].get('display_name', '')
    except Exception:
        pass
    return None, None, ''

def _airbnb_estimate(search_query, room_type, bedroom, person_capacity):
    """Fetch income estimate via Airbnb GraphQL API."""
    payload = {
        "operationName": "GetHostEstimateData",
        "variables": {
            "source": "HOST_LANDING_PAGE",
            "durationGranularity": ["MONTHLY"],
            "location": {"searchQuery": search_query},
            "roomTypeCategory": room_type,
            "bedroom": bedroom,
            "personCapacity": person_capacity,
            "fetchDebugInfo": False,
            "isFIFATreatment": False
        },
        "extensions": {"persistedQuery": {"version": 1, "sha256Hash": AIRBNB_GQL_HASH}}
    }
    tmp = Path("/tmp/_airbnb_payload.json")
    tmp.write_text(json.dumps(payload, ensure_ascii=False))
    r = subprocess.run([
        'curl', '-s', '-X', 'POST',
        'https://www.airbnb.jp/api/v3/GetHostEstimateData?operationName=GetHostEstimateData&locale=ja&currency=JPY',
        '-H', 'Content-Type: application/json',
        '-H', f'X-Airbnb-API-Key: {AIRBNB_API_KEY}',
        '-H', 'User-Agent: Mozilla/5.0',
        '-H', 'Origin: https://www.airbnb.jp',
        '-H', 'Referer: https://www.airbnb.jp/host/homes',
        '-d', f'@{tmp}'
    ], capture_output=True, text=True, timeout=15)
    return json.loads(r.stdout)

def get_airbnb_adr(station_name):
    """
    Get Airbnb ADR for a station area.
    Returns both entire_home (4 guests) and private_room (2 guests) estimates.
    Includes distance verification (station coords vs nearby listings centroid).
    """
    result = {"entire": None, "private": None, "station_geo": "", "error": None}

    time.sleep(1.1)  # Nominatim rate limit
    st_lat, st_lon, st_geo = _geocode_station(station_name)
    if st_lat is None:
        result["error"] = f"駅座標取得失敗: {station_name}"
        return result
    result["station_geo"] = st_geo[:80]

    for cond_key, room_type, capacity in [
        ("entire",  "ENTIRE_HOME",  4),
        ("private", "PRIVATE_ROOM", 2),
    ]:
        try:
            time.sleep(0.8)
            d = _airbnb_estimate(station_name, room_type, 1, capacity)
            screen = d['data']['presentation']['hostEstimate']['hostEstimateScreen']
            secs   = screen['header']['sections']
            elist  = screen['header']['sliderSection']['earningsEstimateListNative']
            markers = screen['mapMarkers']

            per_night_str = secs[1]['value']
            per_night = int(''.join(filter(str.isdigit, per_night_str)))
            avg_nights = int(secs[2]['value'])
            monthly_str = elist[avg_nights - 1] if avg_nights <= len(elist) else elist[-1]
            monthly_est = int(''.join(filter(str.isdigit, monthly_str)))

            coords = [m['coordinate'] for m in markers if m.get('coordinate')]
            dist_km = None
            if coords:
                avg_lat = sum(c['latitude']  for c in coords) / len(coords)
                avg_lon = sum(c['longitude'] for c in coords) / len(coords)
                dist_km = round(_haversine_km(st_lat, st_lon, avg_lat, avg_lon), 1)

            if dist_km is None:     confidence = "❓座標なし"
            elif dist_km <= 1.0:    confidence = f"✅{dist_km}km"
            elif dist_km <= 3.0:    confidence = f"🟡{dist_km}km"
            else:                   confidence = f"⚠️{dist_km}km"

            result[cond_key] = {
                "per_night":   per_night,
                "avg_nights":  avg_nights,
                "occ_pct":     round(avg_nights / 30 * 100),
                "monthly_est": monthly_est,
                "dist_km":     dist_km,
                "confidence":  confidence,
                "returned":    screen['locationDetails']['fullAddress'],
            }
        except Exception as ex:
            result[cond_key] = {"error": str(ex)}

    return result

# ─────────────────────────────────────────────
# Kenbiya login & detail scraping
# ─────────────────────────────────────────────
def kb_login():
    """Login to kenbiya.com via curl. Saves cookie to /tmp/kb_cookies.txt."""
    ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
    r = subprocess.run(
        f'curl -s -c {KB_COOKIE} -b {KB_COOKIE} -H "User-Agent: {ua}" '
        f'"https://www.kenbiya.com/app/exe/login"',
        shell=True, capture_output=True, text=True, timeout=15
    )
    m = re.search(r'name="_csrf" value="([^"]+)"', r.stdout)
    if not m:
        print("kb_login: CSRF token not found", file=sys.stderr)
        return False
    csrf = m.group(1)

    r2 = subprocess.run(
        f'curl -s -D - -c {KB_COOKIE} -b {KB_COOKIE} -H "User-Agent: {ua}" '
        f'-H "Referer: https://www.kenbiya.com/app/exe/login" '
        f'--data-urlencode "login_email={KB_USER}" '
        f'--data-urlencode "password={KB_PASS}" '
        f'--data-urlencode "_csrf={csrf}" '
        f'--data-urlencode "persistent=true" '
        f'"https://www.kenbiya.com/app/exe/loginProcess"',
        shell=True, capture_output=True, text=True, timeout=15
    )
    if "window.location.replace" in r2.stdout or "mypage" in r2.stdout:
        print("kb_login: success", file=sys.stderr)
        return True
    print("kb_login: failed", file=sys.stderr)
    return False

def kb_get_detail(url):
    """
    Fetch Kenbiya property detail page.
    Returns: {"zoning": str, "area_m2": float, "ng_keywords": [str], "detail_ok": bool}
    """
    result = {"zoning": "", "area_m2": None, "ng_keywords": [], "detail_ok": False}
    if not url or "kenbiya.com" not in url:
        return result

    # Re-login if cookie missing or >3 hours old
    need_login = (
        not KB_COOKIE.exists() or
        (datetime.datetime.now().timestamp() - KB_COOKIE.stat().st_mtime) > 10800
    )
    if need_login:
        if not kb_login():
            return result

    ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
    clean_url = url.split("?")[0].rstrip("/") + "/"
    r = subprocess.run(
        f'curl -s -L -c {KB_COOKIE} -b {KB_COOKIE} -H "User-Agent: {ua}" '
        f'-H "Referer: https://www.kenbiya.com/" '
        f'"{clean_url}"',
        shell=True, capture_output=True, text=True, timeout=15
    )
    html = r.stdout
    if not html or "ページが見つかりません" in html:
        if kb_login():
            r = subprocess.run(
                f'curl -s -L -c {KB_COOKIE} -b {KB_COOKIE} -H "User-Agent: {ua}" '
                f'-H "Referer: https://www.kenbiya.com/" '
                f'"{clean_url}"',
                shell=True, capture_output=True, text=True, timeout=15
            )
            html = r.stdout
        if not html or "ページが見つかりません" in html:
            return result

    result["detail_ok"] = True

    m = re.search(r'用途地域</dt>\s*<dd>([^<]+)</dd>', html)
    if m:
        result["zoning"] = m.group(1).strip()

    areas = re.findall(r'専有面積[：:]\s*([\d.]+)\s*m', html)
    if areas:
        result["area_m2"] = min(float(a) for a in areas)

    ng_words = ["シェアハウス", "ゲストハウス", "サ高住",
                "サービス付き高齢者", "グループホーム", "障がい者", "就労支援"]
    result["ng_keywords"] = [w for w in ng_words if w in html]

    return result

# ─────────────────────────────────────────────
# Google Sheets writer
# ─────────────────────────────────────────────
def write_to_spreadsheet(entries):
    """Append screening results to Google Sheets (dedup by msg_id)."""
    import importlib.util, pathlib
    google_api_path = os.environ.get(
        "GOOGLE_API_SCRIPT",
        # Default: Claude Code (hermes) google-workspace skill path
        str(pathlib.Path.home() / ".hermes/skills/productivity/google-workspace/scripts/google_api.py")
    )
    spec = importlib.util.spec_from_file_location("google_api", google_api_path)
    mod  = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    # Add hermes venv site-packages to path (googleapiclient lives there)
    venv_py = pathlib.Path(VENV_PY_PATH)
    # Try to find python3.12 or python3.11 site-packages
    for pyver in ["python3.12", "python3.11", "python3"]:
        venv_site = str(venv_py.parent.parent / f"lib/{pyver}/site-packages")
        if pathlib.Path(venv_site).exists():
            if venv_site not in sys.path:
                sys.path.insert(0, venv_site)
            break

    from googleapiclient.discovery import build

    creds = mod.get_credentials()
    sheets = build('sheets', 'v4', credentials=creds)

    # Get existing msg_ids to prevent duplicates
    try:
        existing = sheets.spreadsheets().values().get(
            spreadsheetId=SPREADSHEET_ID,
            range="物件一覧!Q2:Q"
        ).execute()
        existing_ids = set(row[0] for row in existing.get('values', []) if row)
    except Exception:
        existing_ids = set()

    rows = []
    for e in entries:
        msg_id = e.get("msg_id", "")
        if msg_id and msg_id in existing_ids:
            continue

        prop    = e["prop"]
        scores  = e["scores"]
        sender  = e["sender"]
        subject = e.get("subject", prop.get("title", ""))

        best_pat   = max(scores, key=lambda k: scores[k]["score"])
        best_score = scores[best_pat]["score"]
        if best_score < 40:
            continue

        # Format received date as JST
        raw_date = e.get("date", "")
        try:
            import email.utils, zoneinfo
            dt = email.utils.parsedate_to_datetime(raw_date)
            dt_jst = dt.astimezone(zoneinfo.ZoneInfo("Asia/Tokyo"))
            date_str = dt_jst.strftime("%Y/%m/%d %H:%M")
        except Exception:
            date_str = raw_date[:10] if raw_date else datetime.date.today().strftime("%Y/%m/%d")

        biz_name = sender.get("display_name") or sender.get("sender_name", "")

        if msg_id and GMAIL_ADDR:
            gmail_url  = f"https://mail.google.com/mail/#inbox/{msg_id}?authuser={GMAIL_ADDR}"
            gmail_cell = f'=HYPERLINK("{gmail_url}","📧 開く")'
        elif msg_id:
            gmail_cell = msg_id
        else:
            gmail_cell = ""

        row = [
            date_str,                        # A: 受信日
            biz_name,                        # B: 業者名
            subject[:80],                    # C: 物件名/件名
            prop.get("address", ""),         # D: 所在地
            prop.get("station", ""),         # E: 最寄り駅
            prop.get("walk_min", ""),        # F: 徒歩(分)
            prop.get("price_man", ""),       # G: 価格(万)
            prop.get("yield_pct", ""),       # H: 利回り(%)
            prop.get("structure", ""),       # I: 構造
            prop.get("age", ""),             # J: 築年数
            prop.get("units", ""),           # K: 戸数
            prop.get("zoning", ""),          # L: 用途地域
            best_pat,                        # M: パターン
            best_score,                      # N: スコア
            "新着",                          # O: ステータス
            "",                              # P: メモ
            gmail_cell,                      # Q: Gmailリンク
            "",                              # R: ADR一棟(円/泊)
            "",                              # S: ADR稼働日数
            "",                              # T: ADR月収試算(万円)
        ]

        adr = e.get("adr")
        if best_pat == "A" and adr and not adr.get("error"):
            entire = adr.get("entire") or {}
            if entire and not entire.get("error"):
                row[17] = entire.get("per_night", "")
                row[18] = f"{entire.get('avg_nights','')}泊({entire.get('occ_pct','')}%)"
                row[19] = round(entire.get("monthly_est", 0) / 10000, 1)

        rows.append(row)
        if msg_id:
            existing_ids.add(msg_id)

    if not rows:
        print("Sheets: nothing to append", file=sys.stderr)
        return

    append_result = sheets.spreadsheets().values().append(
        spreadsheetId=SPREADSHEET_ID,
        range="物件一覧!A:T",
        valueInputOption="USER_ENTERED",
        insertDataOption="INSERT_ROWS",
        body={"values": rows}
    ).execute()

    updated_range = append_result.get("updates", {}).get("updatedRange", "")
    print(f"Sheets: appended {len(rows)} rows → {updated_range}", file=sys.stderr)

    # Apply alternating row colors
    try:
        m = re.search(r'!A(\d+):', updated_range)
        if m:
            start_row = int(m.group(1)) - 1
            end_row   = start_row + len(rows)
            _apply_row_format(sheets, start_row, end_row, len(rows))
    except Exception as fe:
        print(f"Format apply error (ignored): {fe}", file=sys.stderr)

def _apply_row_format(sheets, start_row_0idx, end_row_0idx, num_rows):
    """Apply alternating background colors to appended rows."""
    requests = []
    for i in range(num_rows):
        row_idx = start_row_0idx + i
        bg = {"red": 1.0, "green": 1.0, "blue": 1.0} if i % 2 == 0 else \
             {"red": 0.95, "green": 0.96, "blue": 0.98}
        requests.append({
            "repeatCell": {
                "range": {
                    "sheetId": 0,
                    "startRowIndex": row_idx,
                    "endRowIndex": row_idx + 1
                },
                "cell": {
                    "userEnteredFormat": {
                        "backgroundColor": bg,
                        "textFormat": {"fontSize": 10},
                        "verticalAlignment": "MIDDLE"
                    }
                },
                "fields": "userEnteredFormat(backgroundColor,textFormat,verticalAlignment)"
            }
        })

    if requests:
        sheets.spreadsheets().batchUpdate(
            spreadsheetId=SPREADSHEET_ID,
            body={"requests": requests}
        ).execute()

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--days",    type=int, default=1)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--force",   action="store_true")
    args = parser.parse_args()

    date_str  = datetime.date.today().strftime("%Y/%m/%d")
    processed = load_processed()
    all_entries    = []
    rental_entries = []
    new_processed  = set()
    seen_msg_ids   = set()

    print(f"[{date_str}] Property screening v2 (last {args.days} day(s))", file=sys.stderr)

    for query_tmpl in SCAN_QUERIES:
        query = query_tmpl.format(days=args.days)
        emails = search_emails(query, max_results=50)
        print(f"  Query '{query_tmpl.split()[0]}': {len(emails)} emails", file=sys.stderr)

        for msg in emails:
            msg_id  = msg["id"]
            if msg_id in seen_msg_ids:
                continue
            seen_msg_ids.add(msg_id)

            subject  = msg.get("subject", "")
            snippet  = msg.get("snippet", "")
            from_str = msg.get("from", "")
            date_str_mail = msg.get("date", "")

            if msg_id in processed and not args.force:
                continue
            new_processed.add(msg_id)

            if any(kw in subject for kw in SKIP_SUBJECTS):
                print(f"  skip(取引系): {subject[:40]}", file=sys.stderr)
                continue
            if any(re.search(pat, subject) for pat in SKIP_PATTERNS):
                print(f"  skip(PR/広告): {subject[:40]}", file=sys.stderr)
                continue

            sender_info = parse_sender(from_str)
            prop = parse_property(subject, snippet, sender_info)

            if not prop:
                print(f"  skip(物件情報なし): {subject[:40]}", file=sys.stderr)
                continue

            combined = subject + " " + snippet
            skip_type = next((t for t in SKIP_PROPERTY_TYPES if t in combined), None)
            if skip_type:
                print(f"  skip(融資不可:{skip_type}): {subject[:40]}", file=sys.stderr)
                continue

            scores = score_property(prop, sender_info)

            # Fetch body for kenbiya URL extraction or innkeeping keywords
            kb_url    = ""
            body_text = ""
            m_url = re.search(r'https://www\.kenbiya\.com/pp\d+/s/[^\s\r\n"]+', snippet or "")
            needs_body = (
                (not m_url and "kenbiya.com" in sender_info.get("domain", ""))
                or any(kw in subject for kw in ["民泊", "旅館業", "民泊向け", "旅館業物件", "特区民泊"])
            )
            if needs_body:
                try:
                    body_r = subprocess.run(
                        f'{GAPI} gmail get "{msg_id}" 2>/dev/null',
                        shell=True, capture_output=True, text=True, timeout=15
                    )
                    body_data = json.loads(body_r.stdout)
                    body_text = body_data.get("body", "")
                    if not m_url:
                        m_url = re.search(r'https://www\.kenbiya\.com/pp\d+/s/[^\s\r\n"]+', body_text)
                except Exception:
                    pass

            # Update rental detection from body
            if not prop.get("is_rental") and body_text:
                m_rent2 = re.search(r'賃料[：:\s]*約?([\d,]+)万円|月額[：:\s]*約?([\d,]+)万円', body_text)
                if m_rent2:
                    rent_str = m_rent2.group(1) or m_rent2.group(2) or "0"
                    prop["rent_man"] = int(rent_str.replace(",", ""))
                    if not prop.get("yield_pct") and not prop.get("price_man"):
                        prop["is_rental"] = True

            # Update zoning from body if not already set
            if body_text and not prop.get("zoning"):
                for zone in ["商業地域", "近隣商業地域", "準工業地域", "第1種住居地域", "第2種住居地域",
                             "準住居地域", "第一種住居地域", "第二種住居地域"]:
                    if zone in body_text:
                        prop["zoning"] = zone
                        break

            if m_url:
                kb_url = m_url.group(0)

            # Kenbiya detail fetch (high-score properties only)
            best_score_now = max(scores[k]["score"] for k in scores) if scores else 0
            if kb_url and best_score_now >= KB_DETAIL_THRESHOLD:
                detail = kb_get_detail(kb_url)
                if detail.get("zoning") and not prop.get("zoning"):
                    prop["zoning"] = detail["zoning"]
                if detail.get("ng_keywords"):
                    print(f"  skip(詳細NG:{detail['ng_keywords']}): {subject[:40]}", file=sys.stderr)
                    continue
                if detail.get("area_m2") and detail["area_m2"] < 10:
                    print(f"  skip(シェアハウス疑い:{detail['area_m2']}m²): {subject[:40]}", file=sys.stderr)
                    continue
                if detail.get("zoning"):
                    zoning = detail["zoning"]
                    if any(z in zoning for z in ["低層", "中高層", "工業専用", "田園"]):
                        scores["A"]["score"] = 0

            # Station name cleaning
            station_raw   = prop.get("station", "")
            station_clean = ""
            if station_raw:
                m_bracket = re.search(r'「([^」「]{2,10})」駅', station_raw)
                if m_bracket:
                    station_clean = m_bracket.group(1) + "駅"
                else:
                    m_st = re.search(r'([^\s　「」（）()/／]{2,10}駅)', station_raw)
                    station_clean = m_st.group(1) if m_st else ""
            if not station_clean:
                m_st2 = re.search(r'「([^」「]{2,10})」駅|([^\s　「」（）()/／]{2,10}駅)', combined)
                if m_st2:
                    station_clean = (m_st2.group(1) or m_st2.group(2)) + ("駅" if m_st2.group(1) else "")

            # Validate station name
            INVALID_CHARS = set("★☆◆◇■□▲△●○【】｜|%＊*&＆!！?？~～#＃@＠$＄×・")
            if station_clean and (
                any(c in station_clean for c in INVALID_CHARS)
                or len(station_clean) > 12
                or not re.search(r'[\u3040-\u9fff]', station_clean)
            ):
                station_clean = ""

            # Airbnb ADR fetch (only after NG checks, only for confirmed candidates)
            adr_data = None
            a_score = scores.get("A", {}).get("score", 0)
            if station_clean and AIRBNB_API_KEY and (a_score >= 40 or prop.get("is_rental")):
                print(f"  Fetching Airbnb ADR: {station_clean}", file=sys.stderr)
                try:
                    adr_data = get_airbnb_adr(station_clean)
                except Exception as ae:
                    print(f"  ADR fetch failed: {ae}", file=sys.stderr)

            # Extract link from snippet
            link = ""
            m2 = re.search(r'https?://[^\s\)\"]+ ', snippet)
            if m2:
                link = m2.group(0).strip()

            entry = {
                "msg_id":  msg_id,
                "subject": subject,
                "prop":    prop,
                "scores":  scores,
                "sender":  sender_info,
                "link":    kb_url or link,
                "date":    date_str_mail,
                "adr":     adr_data,
            }

            if prop.get("is_rental"):
                rental_entries.append(entry)
                print(f"  ✓[転貸] {subject[:45]}", file=sys.stderr)
            else:
                all_entries.append(entry)
                print(f"  ✓ {subject[:45]}", file=sys.stderr)

    if not args.dry_run:
        save_processed(processed | new_processed)

    report = format_report(all_entries, datetime.date.today().strftime("%Y/%m/%d"), args.days, rental_entries)
    print(report)

    if all_entries and SPREADSHEET_ID and not args.dry_run:
        try:
            write_to_spreadsheet(all_entries)
        except Exception as e:
            print(f"\n⚠️ Sheets write error: {e}", file=sys.stderr)

if __name__ == "__main__":
    main()
