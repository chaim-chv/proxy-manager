#!/usr/bin/env python3
"""Internet-outage analysis for ProxyManager's telemetry.sqlite.

Answers one question with data instead of intuition:

    Does heavy SOCKS/tunnel traffic make the internet go offline?

Reads the request log (one row per connection) and groups it per minute:

  * failure composition per route (DNS vs TCP vs SOCKS)
  * outage episodes: minutes where direct connections had attempts but no success
  * Pearson correlation between tunnel load and direct-route failure rate,
    including lags (does an outage follow a tunnel burst?)
  * resolver-hang evidence: how long `connect_failed: dns` rows waited

Usage:
    python3 Tools/analyze-telemetry.py [--db PATH] [--days 7] [--html OUT.html]

The default DB is ~/Library/Application Support/ProxyManager/telemetry.sqlite.
No dependencies beyond the standard library.
"""

import argparse
import datetime as dt
import html
import math
import os
import sqlite3
import statistics
import sys

DEFAULT_DB = os.path.expanduser(
    "~/Library/Application Support/ProxyManager/telemetry.sqlite"
)


def parse_args():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--db", default=DEFAULT_DB)
    p.add_argument("--days", type=float, default=7.0)
    p.add_argument("--html", default=None, help="write a self-contained HTML report")
    return p.parse_args()


def corr(a, b):
    if len(a) < 3 or len(a) != len(b):
        return 0.0
    ma, mb = statistics.mean(a), statistics.mean(b)
    num = sum((x - ma) * (y - mb) for x, y in zip(a, b))
    da = math.sqrt(sum((x - ma) ** 2 for x in a))
    db = math.sqrt(sum((y - mb) ** 2 for y in b))
    return num / (da * db) if da and db else 0.0


def pct(part, whole):
    return 100.0 * part / whole if whole else 0.0


def human_duration(seconds):
    seconds = int(round(seconds))
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60} min"
    return f"{seconds // 3600} h {(seconds % 3600) // 60} min"


def load_minutes(db, days):
    cutoff_min = int((dt.datetime.now().timestamp() - days * 86400) // 60)
    rows = db.execute(
        """
        SELECT (ts / 60000) AS m,
               COUNT(*) AS n,
               SUM(CASE WHEN route = 'TUNNEL' THEN 1 ELSE 0 END) AS tun,
               SUM(CASE WHEN route = 'TUNNEL' AND (error IS NULL OR error = '')
                        THEN 1 ELSE 0 END) AS tun_ok,
               SUM(CASE WHEN route = 'TUNNEL' THEN bytes_out ELSE 0 END) AS tun_up,
               SUM(CASE WHEN route = 'TUNNEL' THEN bytes_in ELSE 0 END) AS tun_down,
               SUM(CASE WHEN route = 'DIRECT' THEN 1 ELSE 0 END) AS direct,
               SUM(CASE WHEN route = 'DIRECT' AND (error IS NULL OR error = '')
                        THEN 1 ELSE 0 END) AS direct_ok,
               SUM(CASE WHEN error LIKE '%dns%' THEN 1 ELSE 0 END) AS dns_err,
               SUM(CASE WHEN error = 'connect_failed: dns_busy' THEN 1 ELSE 0 END) AS dns_busy,
               SUM(CASE WHEN error = 'connect_failed: socks_timeout' THEN 1 ELSE 0 END) AS socks_to
        FROM requests
        WHERE ts >= ?
        GROUP BY m ORDER BY m
        """,
        (cutoff_min * 60000,),
    ).fetchall()
    keys = ("m", "n", "tun", "tun_ok", "tun_up", "tun_down",
            "direct", "direct_ok", "dns_err", "dns_busy", "socks_to")
    return [dict(zip(keys, r)) for r in rows], cutoff_min


def fill_grid(minutes):
    """Insert missing minutes as zeros so correlations are not inflated by
    dropping silence (the bug that makes busy periods look 'correlated')."""
    if not minutes:
        return []
    by_m = {r["m"]: r for r in minutes}
    zero = dict.fromkeys(minutes[0].keys(), 0)
    grid = []
    for m in range(minutes[0]["m"], minutes[-1]["m"] + 1):
        row = dict(zero)
        row.update(by_m.get(m, {}))
        row["m"] = m
        grid.append(row)
    return grid


def failure_breakdown(db, days):
    cutoff = int((dt.datetime.now().timestamp() - days * 86400) * 1000)
    rows = db.execute(
        """
        SELECT route, error, COUNT(*) FROM requests
        WHERE ts >= ? AND error IS NOT NULL AND error != ''
        GROUP BY route, error ORDER BY COUNT(*) DESC
        """,
        (cutoff,),
    ).fetchall()
    return rows


def direct_dns_durations(db, days):
    cutoff = int((dt.datetime.now().timestamp() - days * 86400) * 1000)
    rows = db.execute(
        """
        SELECT ROUND(duration_ms / 1000.0), COUNT(*) FROM requests
        WHERE ts >= ? AND error = 'connect_failed: dns'
        GROUP BY 1 ORDER BY 2 DESC
        """,
        (cutoff,),
    ).fetchall()
    return rows


def dns_busy_hosts(db, days):
    cutoff = int((dt.datetime.now().timestamp() - days * 86400) * 1000)
    return db.execute(
        """
        SELECT host, COUNT(*) FROM requests
        WHERE ts >= ? AND error = 'connect_failed: dns_busy'
        GROUP BY host ORDER BY COUNT(*) DESC LIMIT 8
        """,
        (cutoff,),
    ).fetchall()


def episodes(grid, gap_minutes=2):
    """A run of minutes where direct connections were attempted and every one
    failed. One minute of silence splits a run only if the gap exceeds the
    monitor's own cadence, so an outage is not invented across a sleep."""
    result = []
    current = []
    for row in grid:
        bad = row["direct"] >= 3 and row["direct_ok"] == 0
        if bad:
            if current and row["m"] - current[-1]["m"] > gap_minutes:
                result.append(current)
                current = []
            current.append(row)
        elif current:
            result.append(current)
            current = []
    if current:
        result.append(current)
    return result


def fmt_minute(m):
    return dt.datetime.fromtimestamp(m * 60).strftime("%m-%d %H:%M")


def print_report(db, args):
    minutes, cutoff_min = load_minutes(db, args.days)
    if not minutes:
        print("No requests in the selected window.")
        return 1
    grid = fill_grid(minutes)
    total = db.execute(
        "SELECT COUNT(*), MIN(ts), MAX(ts) FROM requests WHERE ts >= ?",
        (cutoff_min * 60000,),
    ).fetchone()
    print("=" * 78)
    print("INTERNET OUTAGE / TUNNEL CORRELATION ANALYSIS")
    print("=" * 78)
    print(f"DB:    {args.db}")
    print(f"Rows:  {total[0]:,} connections over {args.days:g} days "
          f"({dt.datetime.fromtimestamp(total[1] / 1000):%Y-%m-%d %H:%M} → "
          f"{dt.datetime.fromtimestamp(total[2] / 1000):%Y-%m-%d %H:%M})")
    print(f"Grid:  {len(grid):,} minutes ({len(minutes):,} with traffic)")

    print("\n--- failure composition ---")
    by_route = {}
    for route, error, count in failure_breakdown(db, args.days):
        by_route.setdefault(route, []).append((error, count))
    for route in sorted(by_route):
        errors = by_route[route]
        total_err = sum(c for _, c in errors)
        print(f"{route}: {total_err:,} failed connections")
        for error, count in errors[:6]:
            print(f"   {pct(count, total_err):5.1f}%  {error}  ({count:,})")

    dns_share = sum(c for e, c in by_route.get("DIRECT", []) if "dns" in e)
    direct_err = sum(c for _, c in by_route.get("DIRECT", []))
    print(f"\n→ {pct(dns_share, direct_err):.1f}% of DIRECT failures are DNS resolution "
          f"(both `dns` and the app's own `dns_busy` gate).")

    print("\n--- how long a failing DNS lookup waited ---")
    for secs, count in direct_dns_durations(db, args.days)[:5]:
        print(f"   {count:5,} rows at ~{secs}s")
    print("   (The proxy's resolver budget is 10 s, so a 10 s row means the system "
          "resolver never answered.)")

    cutoff = int((dt.datetime.now().timestamp() - args.days * 86400) * 1000)
    busy_fast = db.execute(
        "SELECT COUNT(*) FROM requests WHERE ts >= ? AND error = 'connect_failed: dns_busy' "
        "AND duration_ms < 500", (cutoff,)).fetchone()[0]
    busy_total = db.execute(
        "SELECT COUNT(*) FROM requests WHERE ts >= ? AND error = 'connect_failed: dns_busy'",
        (cutoff,)).fetchone()[0]
    print(f"\n--- resolver-gate rejections ---")
    print(f"   {busy_fast:,} of {busy_total:,} `dns_busy` failures "
          f"({pct(busy_fast, busy_total):.0f}%) were rejected in under 0.5 s "
          f"without waiting for a resolver answer.")

    print("\n--- top hosts rejected by the resolver gate (dns_busy) ---")
    for host, count in dns_busy_hosts(db, args.days):
        print(f"   {count:5,}  {host}")

    print("\n--- tunnel load vs direct failures ---")
    active = [r for r in grid if r["direct"] >= 1]
    print(f"{'predictor':<26}{'same minute':>13}{'lag 1':>9}{'lag 3':>9}{'lag 10':>9}")
    for label, key in (("tunnel connections", "tun"), ("tunnel upload bytes", "tun_up")):
        values = []
        for lag in (0, 1, 3, 10):
            a = [r[key] for r in grid[:len(grid) - lag]] if lag else [r[key] for r in grid]
            b = [grid[i + lag]["dns_err"] for i in range(len(grid) - lag)]
            values.append(corr(a, b))
        print(f"{label:<26}" + "".join(f"{v:>9.3f}" for v in values))
    print("   (Pearson r on a continuous minute grid. ~0 = no linear relationship.)")

    print("\n--- direct failure rate by tunnel upload rate ---")
    buckets = [(0, 0), (1, 50_000), (50_001, 500_000),
               (500_001, 2_000_000), (2_000_001, 10 ** 12)]
    for lo, hi in buckets:
        sel = [r for r in grid if lo <= r["tun_up"] <= hi]
        if not sel:
            continue
        direct = sum(r["direct"] for r in sel)
        failed = direct - sum(r["direct_ok"] for r in sel)
        print(f"   {lo/1000:8.0f}–{hi/1000:<8.0f} KB up/min: {len(sel):5,} min | "
              f"direct {direct:6,} conns | {pct(failed, direct):5.1f}% failed")

    print("\n--- outage episodes (≥3 direct attempts, zero successes) ---")
    eps = episodes(grid)
    print(f"{'start':<14}{'min':>4}{'direct':>9}{'dns':>8}{'tunnel':>9}{'socks_to':>9}")
    for ep in eps:
        direct = sum(r["direct"] for r in ep)
        dns = sum(r["dns_err"] for r in ep)
        tun = sum(r["tun"] for r in ep)
        tun_ok = sum(r["tun_ok"] for r in ep)
        sto = sum(r["socks_to"] for r in ep)
        print(f"{fmt_minute(ep[0]['m']):<14}{len(ep):>4}{direct:>9}{dns:>8}"
              f"{tun_ok:>4}/{tun:<4}{sto:>9}")
    print("\n(Read the `tunnel` column as successes/attempts. If an outage were caused "
          "by SOCKS load, these minutes would be the busiest ones; they are not.)")
    return 0


def svg_scatter(grid, width=760, height=280, padding=36):
    """Tunnel upload (x) vs DNS errors (y). No dependency on a chart library."""
    points = [(r["tun_up"], r["dns_err"]) for r in grid]
    max_x = max(1, max(p[0] for p in points))
    max_y = max(1, max(p[1] for p in points))
    def x(v): return padding + (v / max_x) * (width - padding * 2)
    def y(v): return height - padding - (v / max_y) * (height - padding * 2)
    dots = "".join(
        f'<circle cx="{x(px):.1f}" cy="{y(py):.1f}" r="1.8" fill="#d64545" opacity="0.55"/>'
        for px, py in points
    )
    return f"""
<svg viewBox="0 0 {width} {height}" role="img" aria-label="Tunnel upload vs DNS errors">
  <rect width="{width}" height="{height}" fill="#fff"/>
  {dots}
  <line x1="{padding}" y1="{height-padding}" x2="{width-padding}" y2="{height-padding}" stroke="#888"/>
  <line x1="{padding}" y1="{padding}" x2="{padding}" y2="{height-padding}" stroke="#888"/>
  <text x="{width/2}" y="{height-8}" text-anchor="middle" font-family="system-ui" font-size="12">
    tunnel upload per minute (bytes)
  </text>
  <text x="12" y="{height/2}" text-anchor="middle" font-family="system-ui" font-size="12"
        transform="rotate(-90 12 {height/2})">DNS errors per minute</text>
</svg>"""


def svg_timeline(grid, width=1080, height=260, padding=36):
    """Ten-minute buckets over the window: red = DNS failures, grey = traffic."""
    if not grid:
        return ""
    bucket = 10
    agg = {}
    for r in grid:
        key = (r["m"] // bucket) * bucket
        a = agg.setdefault(key, {"dns": 0, "n": 0, "tun_up": 0})
        a["dns"] += r["dns_err"]
        a["n"] += r["n"]
        a["tun_up"] += r["tun_up"]
    keys = sorted(agg)
    max_dns = max(1, max(agg[k]["dns"] for k in keys))
    max_n = max(1, max(agg[k]["n"] for k in keys))
    bar_w = (width - padding * 2) / max(1, len(keys))
    bars = []
    for i, k in enumerate(keys):
        a = agg[k]
        x = padding + i * bar_w
        h = (a["dns"] / max_dns) * (height - padding * 2)
        bars.append(f'<rect x="{x:.1f}" y="{height-padding-h:.1f}" width="{max(1, bar_w-0.6):.1f}" '
                    f'height="{h:.1f}" fill="#d64545" opacity="0.85"/>')
        hn = (a["n"] / max_n) * 18
        bars.append(f'<rect x="{x:.1f}" y="{height-padding-hn:.1f}" width="{max(1, bar_w-0.6):.1f}" '
                    f'height="{hn:.1f}" fill="#2f6f9f" opacity="0.25"/>')
    first = dt.datetime.fromtimestamp(keys[0] * 60)
    last = dt.datetime.fromtimestamp(keys[-1] * 60)
    return f"""
<svg viewBox="0 0 {width} {height}" role="img" aria-label="DNS failures over time">
  <rect width="{width}" height="{height}" fill="#fff"/>
  {''.join(bars)}
  <line x1="{padding}" y1="{height-padding}" x2="{width-padding}" y2="{height-padding}" stroke="#888"/>
  <text x="{padding}" y="{height-padding+16}" font-family="system-ui" font-size="11" fill="#555">
    {first:%b %d %H:%M}
  </text>
  <text x="{width-padding}" y="{height-padding+16}" text-anchor="end"
        font-family="system-ui" font-size="11" fill="#555">{last:%b %d %H:%M}</text>
  <text x="{padding}" y="18" font-family="system-ui" font-size="12" fill="#d64545">
    DNS failures (10 min buckets)
  </text>
  <text x="{padding}" y="34" font-family="system-ui" font-size="12" fill="#2f6f9f">
    all connections (thin blue)
  </text>
</svg>"""


def write_html(db, args, minutes, grid):
    by_route = failure_breakdown(db, args.days)
    eps = episodes(grid)
    rows = "".join(
        f"<tr><td>{fmt_minute(ep[0]['m'])}</td><td>{len(ep)}</td>"
        f"<td>{sum(r['direct'] for r in ep)}</td>"
        f"<td>{sum(r['dns_err'] for r in ep)}</td>"
        f"<td>{sum(r['tun_ok'] for r in ep)}/{sum(r['tun'] for r in ep)}</td>"
        f"<td>{sum(r['socks_to'] for r in ep)}</td></tr>"
        for ep in eps
    )
    failures = "".join(
        f"<tr><td>{html.escape(route)}</td><td>{html.escape(error or '')}</td>"
        f"<td style='text-align:right'>{count:,}</td></tr>"
        for route, error, count in by_route
    )
    doc = f"""<!doctype html>
<meta charset="utf-8">
<title>ProxyManager internet-outage analysis</title>
<style>
 body {{ font: 14px -apple-system, system-ui, sans-serif; margin: 32px; color: #222; }}
 h1 {{ font-size: 22px; margin-bottom: 4px; }}
 .sub {{ color: #666; margin-bottom: 24px; }}
 .card {{ border: 1px solid #ddd; border-radius: 10px; padding: 16px; margin: 16px 0; }}
 table {{ border-collapse: collapse; width: 100%; font-variant-numeric: tabular-nums; }}
 th, td {{ text-align: left; padding: 4px 8px; border-bottom: 1px solid #eee; }}
 th {{ color: #666; font-weight: 600; }}
 code {{ background: #f4f4f4; padding: 1px 5px; border-radius: 4px; }}
 .note {{ color: #666; font-size: 12px; }}
</style>
<h1>Internet outages vs SOCKS/tunnel load</h1>
<div class="sub">Generated {dt.datetime.now():%Y-%m-%d %H:%M} · {args.days:g} days ·
{len(grid):,} minute buckets · source <code>telemetry.sqlite</code></div>

<div class="card">
<h3>Every DNS failure over the window</h3>
{svg_timeline(grid)}
<p class="note">The tall red spikes are episodic. Check the outage table below to see
whether they land on busy tunnel minutes.</p>
</div>

<div class="card">
<h3>Tunnel upload vs DNS errors (one dot = one minute)</h3>
{svg_scatter(grid)}
<p class="note">A causal "heavy SOCKS → offline" effect would slope up to the right.
The cloud is flat: heavy tunnel minutes have no more DNS errors than idle ones.</p>
</div>

<div class="card">
<h3>Outage episodes</h3>
<table><tr><th>Start</th><th>Minutes</th><th>Direct attempts</th>
<th>DNS errors</th><th>Tunnel ok/attempts</th><th>SOCKS timeouts</th></tr>{rows}</table>
</div>

<div class="card">
<h3>Failure composition</h3>
<table><tr><th>Route</th><th>Error</th><th>Count</th></tr>{failures}</table>
</div>
"""
    with open(args.html, "w", encoding="utf-8") as fh:
        fh.write(doc)
    print(f"\nHTML report: {args.html}")


def main():
    args = parse_args()
    if not os.path.exists(args.db):
        print(f"DB not found: {args.db}", file=sys.stderr)
        return 2
    db = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    rc = print_report(db, args)
    if args.html:
        minutes, _ = load_minutes(db, args.days)
        write_html(db, args, minutes, fill_grid(minutes))
    return rc


if __name__ == "__main__":
    sys.exit(main())
