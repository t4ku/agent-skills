#!/usr/bin/env python3
"""
Airbnb ADR Simulator — standalone CLI
Fetches income estimates from the Airbnb host simulator GraphQL API.

Usage:
    python3 airbnb_adr.py "すすきの駅"
    python3 airbnb_adr.py "渋谷駅"
    AIRBNB_API_KEY=<key> AIRBNB_GQL_HASH=<hash> python3 airbnb_adr.py "難波駅"

Requires:
    - AIRBNB_API_KEY env var (or set inline)
    - curl, internet access
    - No external Python deps (stdlib only)
"""

import sys, os, json, math, time, subprocess, tempfile
from pathlib import Path
from urllib.parse import quote

# ─── Config ─────────────────────────────────────────────
API_KEY  = os.environ.get("AIRBNB_API_KEY", "")
# GQL_HASH: get from DevTools → Network → GetHostEstimateData request
#   → Payload → extensions.persistedQuery.sha256Hash
GQL_HASH = os.environ.get("AIRBNB_GQL_HASH", "")
ENDPOINT = "https://www.airbnb.jp/api/v3/GetHostEstimateData?operationName=GetHostEstimateData&locale=ja&currency=JPY"

# ─── Geocoding (Nominatim) ───────────────────────────────
def geocode(query: str):
    """Returns (lat, lon, display_name) or (None, None, '')."""
    r = subprocess.run(
        ["curl", "-s",
         f"https://nominatim.openstreetmap.org/search?q={quote(query)}&format=json&limit=1&accept-language=ja",
         "-H", "User-Agent: airbnb-adr-simulator/1.0"],
        capture_output=True, text=True, timeout=10
    )
    try:
        data = json.loads(r.stdout)
        if data:
            return float(data[0]["lat"]), float(data[0]["lon"]), data[0].get("display_name", "")
    except Exception:
        pass
    return None, None, ""

def haversine_km(lat1, lon1, lat2, lon2):
    R = 6371
    dlat, dlon = math.radians(lat2-lat1), math.radians(lon2-lon1)
    a = math.sin(dlat/2)**2 + math.cos(math.radians(lat1))*math.cos(math.radians(lat2))*math.sin(dlon/2)**2
    return R * 2 * math.asin(math.sqrt(a))

# ─── Airbnb GraphQL ──────────────────────────────────────
def fetch_estimate(search_query: str, room_type: str, bedroom: int = 1, person_capacity: int = 4) -> dict:
    """
    room_type: "ENTIRE_HOME" | "PRIVATE_ROOM"
    Returns raw API response dict.
    """
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
            "isFIFATreatment": False,
        },
        "extensions": {
            "persistedQuery": {"version": 1, "sha256Hash": GQL_HASH}
        },
    }
    with tempfile.NamedTemporaryFile("w", suffix=".json", prefix="airbnb_payload_", dir="/tmp", delete=False) as f:
        tmp = Path(f.name)
        f.write(json.dumps(payload, ensure_ascii=False))

    try:
        r = subprocess.run(
            ["curl", "-s", "-X", "POST", ENDPOINT,
             "-H", "Content-Type: application/json",
             "-H", f"X-Airbnb-API-Key: {API_KEY}",
             "-H", "User-Agent: Mozilla/5.0",
             "-H", "Origin: https://www.airbnb.jp",
             "-H", "Referer: https://www.airbnb.jp/host/homes",
             "-d", f"@{tmp}"],
            capture_output=True, text=True, timeout=15
        )
    finally:
        tmp.unlink(missing_ok=True)
    return json.loads(r.stdout)

def parse_estimate(data: dict) -> dict:
    """
    Extracts per_night, avg_nights, monthly_est, returned_location, markers.
    Raises on parse failure.
    """
    screen  = data["data"]["presentation"]["hostEstimate"]["hostEstimateScreen"]
    secs    = screen["header"]["sections"]
    elist   = screen["header"]["sliderSection"]["earningsEstimateListNative"]
    markers = screen.get("mapMarkers", [])
    loc     = screen["locationDetails"]["fullAddress"]

    per_night  = int("".join(filter(str.isdigit, secs[1]["value"])))
    avg_nights = int(secs[2]["value"])
    idx        = max(0, min(avg_nights - 1, len(elist) - 1))
    monthly    = int("".join(filter(str.isdigit, elist[idx])))

    coords = [m["coordinate"] for m in markers if m.get("coordinate")]

    return {
        "per_night":   per_night,
        "avg_nights":  avg_nights,
        "occ_pct":     round(avg_nights / 30 * 100),
        "monthly_est": monthly,
        "location":    loc,
        "coords":      coords,
    }

# ─── Main ────────────────────────────────────────────────
def get_adr(area: str) -> dict:
    """
    Full pipeline: geocode → fetch ENTIRE_HOME + PRIVATE_ROOM → distance verify.

    Returns:
    {
        "area": str,
        "geocode": {"lat": float, "lon": float, "display": str},
        "entire": {
            "per_night": int, "avg_nights": int, "occ_pct": int,
            "monthly_est": int, "dist_km": float, "confidence": str,
            "location": str
        },
        "private": { ... },
        "error": str | None
    }
    """
    result = {"area": area, "geocode": {}, "entire": None, "private": None, "error": None}

    # Geocode
    time.sleep(1.1)  # Nominatim rate limit
    lat, lon, display = geocode(area)
    if lat is None:
        result["error"] = f"Geocode failed for: {area}"
        return result
    result["geocode"] = {"lat": lat, "lon": lon, "display": display}

    for key, room_type, capacity in [
        ("entire",  "ENTIRE_HOME",  4),
        ("private", "PRIVATE_ROOM", 2),
    ]:
        try:
            time.sleep(0.8)
            raw  = fetch_estimate(area, room_type, bedroom=1, person_capacity=capacity)
            info = parse_estimate(raw)

            # Distance verification
            dist_km = None
            if info["coords"]:
                avg_lat = sum(c["latitude"]  for c in info["coords"]) / len(info["coords"])
                avg_lon = sum(c["longitude"] for c in info["coords"]) / len(info["coords"])
                dist_km = round(haversine_km(lat, lon, avg_lat, avg_lon), 1)

            confidence = (
                f"✅ {dist_km}km" if dist_km is not None and dist_km <= 1.0 else
                f"🟡 {dist_km}km" if dist_km is not None and dist_km <= 3.0 else
                f"⚠️ {dist_km}km" if dist_km is not None else
                "❓ no coords"
            )
            result[key] = {**info, "dist_km": dist_km, "confidence": confidence}
        except Exception as e:
            result[key] = {"error": str(e)}

    return result


def print_result(r: dict):
    print(f"\n📍 {r['area']} → {r['geocode'].get('display','')[:80]}")

    for key, label, room_label in [
        ("entire",  "一棟貸し", "ENTIRE_HOME / 1BD / 4名"),
        ("private", "一室貸し", "PRIVATE_ROOM / 1BD / 2名"),
    ]:
        d = r.get(key)
        if not d:
            continue
        if d.get("error"):
            print(f"\n{'🏨' if key=='entire' else '🛏'} {label} ({room_label})")
            print(f"   エラー: {d['error']}")
            continue
        print(f"\n{'🏨' if key=='entire' else '🛏'} {label} ({room_label})")
        print(f"   単価:   ¥{d['per_night']:,}/泊")
        print(f"   稼働:   {d['avg_nights']}泊/月 ({d['occ_pct']}%)")
        print(f"   月収:   ¥{d['monthly_est']:,}")
        print(f"   距離:   {d['confidence']}")
        print(f"   地点:   {d['location']}")
    print()


if __name__ == "__main__":
    if not API_KEY:
        print("Error: AIRBNB_API_KEY not set", file=sys.stderr)
        sys.exit(1)
    if not GQL_HASH:
        print("Error: AIRBNB_GQL_HASH not set (get from DevTools)", file=sys.stderr)
        sys.exit(1)

    areas = sys.argv[1:] if len(sys.argv) > 1 else ["すすきの駅"]

    for area in areas:
        r = get_adr(area)
        if r["error"]:
            print(f"Error: {r['error']}", file=sys.stderr)
        else:
            print_result(r)
