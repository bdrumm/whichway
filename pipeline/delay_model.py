"""Fit the delay-alert lifecycle model and write it out, with the report of the modelling exercise.

    python -m pipeline.delay_model --store data/mta.sqlite --out data/delay_model.json --report docs/delay_model_report.md

The alerts and the polling windows come from a collector store (the Mac's, which polls for hours at a stretch and
keeps each alert's real last-seen time); the arrivals in the same store give when the line recovered. The daily
archive on the data branch can be added with --data-dir once its last-seen times are per alert (Oct 10 2026 on).
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import time
from pathlib import Path

import numpy as np
import pandas as pd

from mta_delay_insights.analysis import delay_lifecycle as dl
from mta_delay_insights.analysis.schedule_match import match_arrivals
from mta_delay_insights.sources.alerts import classify_cause
from pipeline import lib


def load_store(path: Path) -> tuple[pd.DataFrame, list[tuple[float, float]], sqlite3.Connection]:
    con = sqlite3.connect(str(path))
    snap = pd.read_sql("select fetched_at from snapshots", con)
    windows = dl.polling_windows(snap["fetched_at"].values)
    al = pd.read_sql("select * from alerts", con)
    for c in ("routes", "stops"):
        al[c] = al[c].map(lambda v: json.loads(v) if isinstance(v, str) and v.startswith("[") else [])
    al["planned"] = al["planned"].astype(bool)
    al["cause_category"] = al["header"].map(classify_cause)        # the classifier may have learnt since the row was stored
    return al, windows, con


def arrivals_around(con: sqlite3.Connection, events: pd.DataFrame, before_sec: float = 3600, after_sec: float = 4 * 3600) -> pd.DataFrame:
    """The store's arrivals inside the windows the events span, on their routes only."""
    if events.empty:
        return pd.DataFrame()
    spans: list[tuple[float, float, tuple[str, ...]]] = [(r.start_ts - before_sec, min(r.end_ts, r.start_ts + after_sec), tuple(r.routes)) for r in events.itertuples()]
    lo, hi = min(s[0] for s in spans), max(s[1] for s in spans)
    a = pd.read_sql("select trip_key, trip_id, route_id, start_date, direction, stop_id, arrival_ts from arrivals where arrival_ts between ? and ?", con, params=(lo, hi))
    if a.empty:
        return a
    ts = a["arrival_ts"].values
    keep = np.zeros(len(a), dtype=bool)
    routes = a["route_id"].astype(str).values
    for s, e, rs in spans:
        m = (ts >= s) & (ts <= e)
        if rs:
            m &= np.isin(routes, list(rs))
        keep |= m
    return a[keep].reset_index(drop=True)


def report(model: dict, events: pd.DataFrame, rec: pd.DataFrame, sources: dict) -> str:
    L = model["lifetime"]
    g = model["grid_min"]
    def s_at(curve, t):
        i = int(t // g)
        return curve[i] if 0 <= i < len(curve) else None
    lines = []
    lines.append("# Delay alerts: how long they live, how long the delay lives, and the gap\n")
    lines.append(f"Generated {time.strftime('%Y-%m-%d %H:%M', time.localtime(model['generated_at']))} from {sources['store']}: "
                 f"{model['n_events']} unplanned delay alerts (Staten Island Railway excluded) between "
                 f"{sources['first_day']} and {sources['last_day']}, over {sources['polling_hours']:.0f} hours of polling in {sources['windows']} spans; "
                 f"{model['n_ended']} ends were observed, the rest are censored where polling stopped (Kaplan–Meier throughout).\n")
    lines.append("## 1. Lifetime of an alert\n")
    a = L["all"]
    lines.append(f"Still posted after 30 min: {s_at(a['survival'], 30):.0%} · 60 min: {s_at(a['survival'], 60):.0%} · 2 h: {s_at(a['survival'], 120):.0%} · 4 h: {s_at(a['survival'], 240):.0%}. "
                 f"Median {a['p50']:.0f} min, lower quartile {a['p25']:.0f} min; about a quarter of alerts are still up six hours later, the standing ones.\n")
    lines.append("| cause | n | median min | p75 min | still up at 2 h |\n|---|---|---|---|---|")
    for c, v in sorted(L["by_cause"].items(), key=lambda kv: -kv[1]["n"]):
        lines.append(f"| {c} | {v['n']} | {v['p50'] or '>360'} | {v['p75'] or '>360'} | {s_at(v['survival'], 120):.0%} |")
    lines.append("\n| line | n | median min | still up at 2 h |\n|---|---|---|---|")
    for r, v in sorted(L["by_route"].items(), key=lambda kv: -kv[1]["n"]):
        lines.append(f"| {r} | {v['n']} | {v['p50'] or '>360'} | {s_at(v['survival'], 120):.0%} |")
    lines.append("\n| time band | n | median min |\n|---|---|---|")
    for b, v in L["by_band"].items():
        lines.append(f"| {b} | {v['n']} | {v['p50'] or '>360'} |")
    lines.append("\n## 2. The MTA's stated end\n")
    se = L.get("stated_end", {})
    if se:
        lines.append(f"{se['n']} alerts carried a stated end, a median {se['median_stated_min']:.0f} min after creation (quartiles {se['p25_stated_min']:.0f}–{se['p75_stated_min']:.0f}). "
                     f"Of the {se['n_ended']} whose end was observed, {se['share_expired_on_time']:.0%} vanished within three minutes of it, "
                     f"{se['share_withdrawn_early']:.0%} were withdrawn earlier, and {se['share_extended']:.0%} were extended past it, by a median {se['median_extension_min']:.0f} min. "
                     "So the stated end is a deadline that is kept or pushed, not a forecast of the delay: the realtime score runs on time relative to it.\n")
        rel = L["relative"]["all"]["survival"]
        rg = L["relative"]["grid_start"]
        def r_at(t):
            i = int((t - rg) // g)
            return rel[i] if 0 <= i < len(rel) else None
        lines.append(f"Relative to the stated end, the share still posted: 30 min before {r_at(-30):.0%} · at it {r_at(0):.0%} · 10 min after {r_at(10):.0%} · 30 min after {r_at(30):.0%} · 2 h after {r_at(120):.0%}.\n")
    lines.append("## 3. Where and when\n")
    st = sorted(L["by_station"].items(), key=lambda kv: -kv[1]["n"])[:15]
    lines.append("| station named | alerts | median min | lines | causes |\n|---|---|---|---|---|")
    for s, v in st:
        lines.append(f"| {s} | {v['n']} | {v['p50'] or '>360'} | {' '.join(v['routes'])} | {', '.join(f'{k} {n}' for k, n in v['causes'].items())} |")
    lines.append(f"\nA station is named in {events['station'].notna().mean():.0%} of alerts; the direction in {1 - L['direction_share'].get('unknown', 0):.0%}.\n")
    lines.append("## 4. Staleness: the alert against the feed\n")
    stl = model["stale"]
    if stl.get("all"):
        s = stl["all"]
        lines.append(f"{stl['n_followed']} alerts could be followed in the feed: the lateness of arrivals per 10 min on the alert's lines, at the stops within three of the "
                     f"station it names in the direction it names ({stl['share_local']:.0%} of them; the whole line otherwise), against the hour before the alert less its last ten minutes. "
                     f"The feed showed a delay of two minutes or more over that baseline for {stl['share_delay_seen']:.0%} of alerts ({stl['n_delay_seen']}); the rest never registered there, "
                     f"a delay too local or too brief for the arrivals to carry, or one the alert overstated.\n")
        lines.append(f"Where a delay showed and then cleared ({stl['n_measured']} alerts): the stops were back to normal a median {s['median_recovery_min']:.0f} min after the alert was posted, "
                     f"and the alert stayed up a median {s['median_lag_min']:.0f} min after that (upper quartile {s['p75_lag_min']:.0f}); "
                     f"{s['share_removed_within_15']:.0%} were gone within 15 min of the feed looking normal, {s['share_removed_within_30']:.0%} within 30.\n")
        lines.append("| cause | n | recovery after min | alert outlives by min | gone within 30 min of recovery |\n|---|---|---|---|---|")
        for c, v in sorted(stl["by_cause"].items(), key=lambda kv: -kv[1]["n"]):
            lines.append(f"| {c} | {v['n']} | {v['median_recovery_min']:.0f} | {v['median_lag_min']:.0f} | {v['share_removed_within_30']:.0%} |")
    else:
        lines.append("No alert could be followed in the feed (no matching arrivals in the store).\n")
    lines.append("\n## 5. The realtime score\n")
    lines.append("For a live alert the service reports when it was posted and where (the station in the text, the lines, the direction), its age, "
                 "and from the curves above: the chance it is gone within 15, 30 and 60 minutes and the expected remaining minutes, taken from the "
                 "curve relative to the MTA's stated end when there is one (the cause's curve, shrunk toward all alerts), else from age since creation. "
                 "The feed is then read against it: the line's lateness and held trains now. A line that has looked normal for a while while the alert "
                 "stands is scored stale with the table in section 4: the share of such alerts that were gone within 30 minutes of recovery.\n")
    lines.append("## Limits\n")
    lines.append("Two weeks of alerts from one collector; ends are only observed while it polls; the station is read from the text, which names "
                 "the place of the cause rather than every stop affected; the feed's lateness is a median over the whole line, so a localised delay "
                 "can read as recovered while one segment still crawls. The curves shrink toward their parents, so thin groups lean on the overall shape.\n")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--store", default="data/mta.sqlite")
    ap.add_argument("--gtfs", default="data/gtfs_subway.zip")
    ap.add_argument("--out", default="data/delay_model.json")
    ap.add_argument("--report", default="docs/delay_model_report.md")
    ap.add_argument("--lines", default="ios/WhichWay/WhichWay/Resources/Seed/client_schedule.json",
                    help="the client schedule, for the stops around a named station")
    ap.add_argument("--no-recovery", action="store_true", help="skip the arrivals matching (the stale tables)")
    args = ap.parse_args()

    al, windows, con = load_store(Path(args.store))
    ev = dl.live_events(al, windows=windows)
    tables = dl.lifecycle_tables(ev)
    stale: dict = {"n_measured": 0}
    rec = pd.DataFrame()
    if not args.no_recovery and len(ev):
        static = lib.load_static(args.gtfs)
        lines = {}
        if Path(args.lines).exists():
            lines = json.loads(Path(args.lines).read_text()).get("lines", {})
        arr = arrivals_around(con, ev)
        if not arr.empty:
            matched = match_arrivals(arr, static)
            bins = dl.stop_lateness_bins(matched)
            rec = dl.recovery_lag(ev, bins, windows, lines=lines)
            stale = dl.stale_tables(rec)
    sources = {"store": args.store, "windows": len(windows), "polling_hours": sum(b - a for a, b in windows) / 3600,
               "first_day": time.strftime("%Y-%m-%d", time.localtime(ev["start_ts"].min())) if len(ev) else None,
               "last_day": time.strftime("%Y-%m-%d", time.localtime(ev["end_ts"].max())) if len(ev) else None}
    model = dl.build_model(tables, stale, time.time(), sources)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(dl.dumps(model))
    rp = Path(args.report)
    rp.parent.mkdir(parents=True, exist_ok=True)
    rp.write_text(report(model, ev, rec, sources))
    print(f"{len(ev)} alerts, {tables.get('n_ended', 0)} ends observed, {stale.get('n_measured', 0)} followed in the feed -> {out} ({out.stat().st_size // 1024} KB), {rp}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
