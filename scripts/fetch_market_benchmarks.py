#!/usr/bin/env python3
"""
Fetches official daily U.S. macro, rates, repo, agency, equity, and volatility benchmarks
(2020-01-01 through present) from Federal Reserve Economic Data (FRED) and the
Federal Reserve Bank of New York Markets API, outputting a compact date-keyed JSON bundle
for the EDGAR Deal & Market Trends Observatory (`Web/public/assets/market-benchmarks.json`).
"""

import concurrent.futures
import csv
import io
import json
import os
import subprocess
from datetime import datetime, timezone

START_DATE = "2020-01-01"

FRED_SERIES = {
    "spx": "SP500",             # S&P 500 Index (Close)
    "ixic": "NASDAQCOM",        # Nasdaq Composite Index (Close)
    "vix": "VIXCLS",            # CBOE Volatility Index (VIX)
    "sofr": "SOFR",             # Secured Overnight Financing Rate (%)
    "tgcr": "TGCRRATE",         # Tri-Party General Collateral Repo Rate (%)
    "onRrp": "RRPONTSYAWARD",   # Fed Overnight Reverse Repo Award Rate (%)
    "effr": "DFF",              # Effective Federal Funds Rate (%)
    "ust3m": "DGS3MO",          # 3-Month Treasury Constant Maturity (%)
    "ust2y": "DGS2",            # 2-Year Treasury Constant Maturity (%)
    "ust10y": "DGS10",          # 10Y Treasury Constant Maturity (%)
    "curve2s10s": "T10Y2Y",     # 10Y Minus 2Y Treasury Spread (%)
    "agency30y": "OBMMIC30YF",  # 30-Year Conforming Agency Mortgage Index (%)
}


def curl_get(url: str) -> str:
    return subprocess.check_output(
        ["curl", "-fsSL", "--retry", "3", "--max-time", "20", url],
        text=True,
    )


def fetch_fred_csv(series_id: str) -> dict[str, float]:
    url = f"https://fred.stlouisfed.org/graph/fredgraph.csv?id={series_id}&cosd={START_DATE}"
    raw = curl_get(url)
    out: dict[str, float] = {}
    reader = csv.reader(io.StringIO(raw))
    header = next(reader, None)
    if not header:
        return out
    for row in reader:
        if len(row) < 2:
            continue
        dt, val = row[0].strip(), row[1].strip()
        if not dt or not val or val == ".":
            continue
        try:
            out[dt] = round(float(val), 4)
        except ValueError:
            continue
    return out


def fetch_nyfed_bgcr() -> dict[str, float]:
    url = f"https://markets.newyorkfed.org/api/rates/secured/bgcr/search.json?startDate={START_DATE}"
    payload = json.loads(curl_get(url))
    out: dict[str, float] = {}
    for item in payload.get("refRates", []):
        dt = item.get("effectiveDate")
        rate = item.get("percentRate")
        if dt and rate is not None:
            try:
                out[dt] = round(float(rate), 4)
            except (TypeError, ValueError):
                continue
    return out


def main() -> None:
    series_maps: dict[str, dict[str, float]] = {}
    all_dates: set[str] = set()

    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        futs = {pool.submit(fetch_fred_csv, fid): (k, fid) for k, fid in FRED_SERIES.items()}
        bgcr_fut = pool.submit(fetch_nyfed_bgcr)

        for fut in concurrent.futures.as_completed(futs):
            key, fred_id = futs[fut]
            data = fut.result()
            series_maps[key] = data
            all_dates.update(data.keys())
            sorted_d = sorted(data.keys())
            print(f"Loaded {key:11s} ({fred_id:13s}): {len(data):4d} obs [{sorted_d[0]} -> {sorted_d[-1]}]")

        bgcr = bgcr_fut.result()
        series_maps["bgcr"] = bgcr
        all_dates.update(bgcr.keys())
        sorted_bgcr = sorted(bgcr.keys())
        print(f"Loaded {'bgcr':11s} ({'NYFed BGCR':13s}): {len(bgcr):4d} obs [{sorted_bgcr[0]} -> {sorted_bgcr[-1]}]")

    sorted_dates = sorted(d for d in all_dates if d >= START_DATE)

    keys_order = [
        "spx",
        "ixic",
        "vix",
        "sofr",
        "tgcr",
        "bgcr",
        "onRrp",
        "effr",
        "ust3m",
        "ust2y",
        "ust10y",
        "curve2s10s",
        "agency30y",
        "agencySpreadBps",
    ]

    last_seen: dict[str, float] = {}
    by_date: dict[str, list[float | None]] = {}

    for dt in sorted_dates:
        for k in keys_order:
            if k == "agencySpreadBps":
                continue
            val = series_maps.get(k, {}).get(dt)
            if val is not None:
                last_seen[k] = val

        row: list[float | None] = []
        for k in keys_order:
            if k == "agencySpreadBps":
                ag = last_seen.get("agency30y")
                u10 = last_seen.get("ust10y")
                if ag is not None and u10 is not None:
                    row.append(round((ag - u10) * 100.0, 1))
                else:
                    row.append(None)
            else:
                v = last_seen.get(k)
                row.append(round(v, 3) if v is not None else None)
        by_date[dt] = row

    out_obj = {
        "generatedAtISO8601": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sources": [
            "Federal Reserve Board H.15 & FRED (Federal Reserve Bank of St. Louis)",
            "Federal Reserve Bank of New York Markets API (SOFR, TGCR, BGCR, EFFR, ON RRP)",
            "S&P Dow Jones Indices / CBOE / Nasdaq / Optimal Blue Conforming Agency Index",
        ],
        "fields": keys_order,
        "byDate": by_date,
    }

    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_path = os.path.join(repo_root, "Web", "public", "assets", "market-benchmarks.json")
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out_obj, f, separators=(",", ":"))

    size_kb = os.path.getsize(out_path) / 1024.0
    print(f"Wrote {len(by_date)} daily rows ({size_kb:.1f} KB) to {out_path}")


if __name__ == "__main__":
    main()
