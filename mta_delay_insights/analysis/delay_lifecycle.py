"""How long a delay alert lives, how long the delay it describes lives, and the gap between the two.

The collector keeps every unplanned alert with when the MTA created it and when the feed last carried it, in
polling runs of about fifty minutes several times a day, so an alert's end is often only known to be *after* the
run ended (right-censored). The archive of arrivals says when trains on the line were back on time. From these:

- the lifetime of an alert by line, cause, time band and station, as a Kaplan–Meier survival curve, shrunk
  toward its parents (line and cause toward all alerts) where a group is thin;
- the MTA's own stated end against the real one;
- the recovery lag: how long an alert outlived the delay the feed could see (its staleness);
- the tables the realtime service and the app score a live alert with: P(cleared within h | age), expected
  remaining minutes, and P(cleared soon | the feed already looks normal).
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field

import numpy as np
import pandas as pd

from ..realtime.client_model import band_at
from ..sources.alerts import alert_kind

GRID_MIN = 10
GRID = np.arange(0, 361, GRID_MIN)          # minutes since creation: 0 … 360
REL_GRID = np.arange(-120, 301, GRID_MIN)   # minutes relative to the MTA's stated end: -120 … +300
SHRINK_K = 15.0                              # a group's own curve carries weight n / (n + K)
EXCLUDE_ROUTES = {"SI"}                      # Staten Island Railway "delays" are standing boarding notices
STATION_RE = re.compile(
    r"\b(?:at|near|between|in)\s+((?:[A-Z0-9][\w.'’/&-]*|of)(?:\s+(?:[A-Z0-9][\w.'’/&-]*|of|-))*)"
)
STOP_WORDS = ("Manhattan", "Brooklyn", "Queens", "Bronx", "Staten Island", "NYPD", "FDNY", "EMS", "NYC", "MTA")
DIRECTION_RE = [
    ("both", r"both directions"), ("N", r"\buptown\b|\bnorthbound\b|manhattan-bound (?:\[\w+\])*|bronx-bound|queens-bound"),
    ("S", r"\bdowntown\b|\bsouthbound\b|brooklyn-bound"),
]


# ---------------------------------------------------------------- the events

def extract_station(header: str) -> str | None:
    """The station the header names ("…track maintenance at Grand Central-42 St."), if any."""
    h = (header or "").replace(" ", " ")
    for m in STATION_RE.finditer(h):
        name = m.group(1).strip(" .,;:")
        name = re.sub(r"\s+(and|while|because|due|after|when|for|with|in|on)$", "", name)
        if not name or name in STOP_WORDS or len(name) < 3:
            continue
        if re.match(r"^(the|a|an|this|that|our|its)\b", name, re.I):
            continue
        return name
    return None


def extract_direction(header: str) -> str:
    h = (header or "").lower()
    for tag, pat in DIRECTION_RE:
        if re.search(pat, h):
            return tag
    return "unknown"


def collect_windows(runs: list[dict]) -> list[tuple[float, float]]:
    """The spans the collector was polling in, from the run records."""
    out: list[tuple[float, float]] = []
    for r in runs:
        if r.get("kind") != "collect":
            continue
        per = r.get("per_feed")
        if isinstance(per, list) and per:
            a = min(p.get("first_ts", np.inf) for p in per)
            b = max(p.get("last_ts", 0) for p in per)
            if np.isfinite(a) and b > 0:
                out.append((float(a), float(b)))
        elif r.get("ts") and r.get("duration_sec"):
            out.append((float(r["ts"]) - float(r["duration_sec"]), float(r["ts"])))
    return sorted(out)


def polling_windows(fetched_at: np.ndarray, gap_sec: float = 300.0) -> list[tuple[float, float]]:
    """The spans a store was polling in, from its snapshot times: a gap longer than `gap_sec` ends a span."""
    t = np.sort(np.asarray(fetched_at, dtype=float))
    if t.size == 0:
        return []
    cuts = np.where(np.diff(t) > gap_sec)[0]
    starts = np.concatenate([[0], cuts + 1])
    ends = np.concatenate([cuts, [t.size - 1]])
    return [(float(t[s]), float(t[e])) for s, e in zip(starts, ends)]


def live_events(alerts: pd.DataFrame, runs: list[dict] | None = None, censor_slack_sec: float = 240.0,
                windows: list[tuple[float, float]] | None = None, types: tuple[str, ...] = ("delays",)) -> pd.DataFrame:
    """One row per unplanned delay alert (`types`: substrings of the alert type, lower case), with its lifetime and
    whether the end was seen (the feed dropped it while polling) or only bounded (polling stopped first)."""
    cols = ["event_id", "alert_id", "start_ts", "end_ts", "duration_min", "censored", "routes", "cause", "kind", "band",
            "station", "direction", "stated_end_min", "header"]
    if alerts is None or alerts.empty:
        return pd.DataFrame(columns=cols)
    a = alerts.copy()
    a["kind"] = [alert_kind(t, h) for t, h in zip(a["alert_type"], a["header"])]
    a = a[(a["kind"] == "delay") & a["created_at"].notna() & a["last_seen_ts"].notna()]
    if types:
        a = a[a["alert_type"].fillna("").str.lower().map(lambda t: any(x in t for x in types))]
    a = a.sort_values("last_seen_ts").drop_duplicates(["alert_id", "active_start"], keep="last")
    windows = windows if windows is not None else collect_windows(runs or [])
    ends = np.array([w[1] for w in windows]) if windows else np.array([])
    rows = []
    for r in a.itertuples(index=False):
        start = float(r.created_at)
        end = float(r.last_seen_ts)
        if end <= start:
            continue
        censored = False
        if ends.size:
            censored = bool(np.any(np.abs(ends - end) <= censor_slack_sec))
        routes = [str(x) for x in (r.routes or [])] if isinstance(r.routes, (list, tuple)) else []
        if routes and set(routes) <= EXCLUDE_ROUTES:
            continue
        routes = [x for x in routes if x not in EXCLUDE_ROUTES]
        rows.append({
            "event_id": f"{r.alert_id}|{int(r.active_start) if pd.notna(r.active_start) else 0}", "alert_id": r.alert_id,
            "start_ts": start, "end_ts": end, "duration_min": (end - start) / 60.0, "censored": censored,
            "routes": routes, "cause": r.cause_category or "unknown", "kind": str(r.alert_type or "").lower(),
            "band": band_at(start), "station": extract_station(r.header), "direction": extract_direction(r.header),
            "stated_end_min": (float(r.active_end) - start) / 60.0 if pd.notna(r.active_end) and float(r.active_end) > start else np.nan,
            "header": r.header,
        })
    return pd.DataFrame(rows, columns=cols)


# ---------------------------------------------------------------- survival

def km_survival(duration_min: np.ndarray, censored: np.ndarray, grid: np.ndarray = GRID,
                entry_min: np.ndarray | None = None) -> np.ndarray:
    """Kaplan–Meier S(t) on the grid: the share of alerts still posted at t. With `entry_min` (left truncation)
    each alert only counts in the risk set from its own entry time on, which lets t run relative to a point such
    as the stated end rather than from creation."""
    d = np.asarray(duration_min, dtype=float)
    c = np.asarray(censored, dtype=bool)
    e = np.asarray(entry_min, dtype=float) if entry_min is not None else np.full(d.shape, -np.inf)
    if d.size == 0:
        return np.ones(len(grid))
    times = np.unique(d[~c]) if (~c).any() else np.array([])
    s = 1.0
    out = np.ones(len(grid))
    gi = 0
    for t in times:
        at_risk = int(np.sum((e < t) & (d >= t)))
        events = int(np.sum((d == t) & ~c))
        if at_risk > 0:
            s *= 1.0 - events / at_risk
        while gi < len(grid) and grid[gi] < t:
            gi += 1
        out[gi:] = s
    # before the first entry the curve is undefined; hold it at 1
    return np.clip(out, 0.0, 1.0)


def shrink_curve(own: np.ndarray, parent: np.ndarray, n: int, k: float = SHRINK_K) -> np.ndarray:
    w = n / (n + k)
    return w * own + (1 - w) * parent


def curve_stats(s: np.ndarray, grid: np.ndarray = GRID) -> dict:
    """Median and quartiles of the lifetime from a survival curve (None where the curve never gets there)."""
    def q(p: float):
        idx = np.where(s <= 1 - p)[0]
        return float(grid[idx[0]]) if idx.size else None
    return {"p25": q(0.25), "p50": q(0.5), "p75": q(0.75), "p90": q(0.9),
            "expected_min": float(np.trapezoid(s, grid)) if hasattr(np, "trapezoid") else float(np.trapz(s, grid))}


@dataclass
class Group:
    name: str
    n: int
    n_ended: int
    curve: list[float]
    stats: dict
    extra: dict = field(default_factory=dict)

    def as_dict(self) -> dict:
        d = {"n": self.n, "n_ended": self.n_ended, "survival": [round(float(x), 4) for x in self.curve], **self.stats}
        d.update(self.extra)
        return d


def _group(name: str, ev: pd.DataFrame, parent: np.ndarray) -> Group:
    own = km_survival(ev["duration_min"].values, ev["censored"].values)
    s = shrink_curve(own, parent, len(ev))
    return Group(name, int(len(ev)), int((~ev["censored"]).sum()), list(s), curve_stats(s))


def lifecycle_tables(events: pd.DataFrame, min_n: int = 5) -> dict:
    """The survival curves by line, cause, band, line×cause and station, each shrunk toward its parent."""
    ev = events[events["duration_min"] > 0].copy()
    out: dict = {"grid_min": int(GRID_MIN), "n_events": int(len(ev)), "n_ended": int((~ev["censored"]).sum())}
    if ev.empty:
        return out
    glob = km_survival(ev["duration_min"].values, ev["censored"].values)
    out["all"] = Group("all", len(ev), int((~ev["censored"]).sum()), list(glob), curve_stats(glob)).as_dict()
    exploded = ev.explode("routes").rename(columns={"routes": "route"})
    exploded = exploded[exploded["route"].notna()]
    out["by_route"] = {}
    route_curves: dict[str, np.ndarray] = {}
    for route, g in exploded.groupby("route"):
        if len(g) < min_n:
            continue
        grp = _group(route, g, glob)
        route_curves[route] = np.array(grp.curve)
        out["by_route"][route] = grp.as_dict()
    out["by_cause"] = {}
    cause_curves: dict[str, np.ndarray] = {}
    for cause, g in ev.groupby("cause"):
        if len(g) < min_n:
            continue
        grp = _group(cause, g, glob)
        cause_curves[cause] = np.array(grp.curve)
        out["by_cause"][cause] = grp.as_dict()
    out["by_band"] = {}
    for band, g in ev.groupby("band"):
        if len(g) < min_n:
            continue
        out["by_band"][band] = _group(band, g, glob).as_dict()
    out["by_route_cause"] = {}
    for (route, cause), g in exploded.groupby(["route", "cause"]):
        if len(g) < min_n:
            continue
        parent = 0.5 * route_curves.get(route, glob) + 0.5 * cause_curves.get(cause, glob)
        out["by_route_cause"][f"{route}|{cause}"] = _group(f"{route}|{cause}", g, parent).as_dict()
    out["by_station"] = {}
    st = ev[ev["station"].notna()]
    for station, g in st.groupby("station"):
        if len(g) < 2:
            continue
        grp = _group(station, g, glob)
        grp.extra = {"causes": g["cause"].value_counts().head(3).to_dict(),
                     "routes": sorted({r for rs in g["routes"] for r in rs})}
        out["by_station"][station] = grp.as_dict()
    # the MTA's own stated end: alerts expire on it, are withdrawn before it, or are extended past it
    se = ev[ev["stated_end_min"].notna()].copy()
    if len(se):
        se["rel"] = se["duration_min"] - se["stated_end_min"]
        ended = se[~se["censored"]]
        out["stated_end"] = {
            "n": int(len(se)), "n_ended": int(len(ended)), "median_stated_min": float(se["stated_end_min"].median()),
            "p25_stated_min": float(se["stated_end_min"].quantile(0.25)), "p75_stated_min": float(se["stated_end_min"].quantile(0.75)),
            "share_expired_on_time": float((ended["rel"].abs() <= 3).mean()) if len(ended) else None,
            "share_withdrawn_early": float((ended["rel"] < -3).mean()) if len(ended) else None,
            "share_extended": float((ended["rel"] > 3).mean()) if len(ended) else None,
            "median_extension_min": float(ended.loc[ended["rel"] > 3, "rel"].median()) if (ended["rel"] > 3).any() else None,
        }
        # survival relative to the stated end: the realtime score for an alert whose end the MTA has stated
        rel_all = km_survival(se["rel"].values, se["censored"].values, REL_GRID, entry_min=-se["stated_end_min"].values)
        out["relative"] = {"grid_min": int(GRID_MIN), "grid_start": int(REL_GRID[0]),
                           "all": {"n": int(len(se)), "survival": [round(float(x), 4) for x in rel_all]}, "by_cause": {}, "by_route": {}}
        for cause, g in se.groupby("cause"):
            if len(g) < min_n:
                continue
            own = km_survival(g["rel"].values, g["censored"].values, REL_GRID, entry_min=-g["stated_end_min"].values)
            out["relative"]["by_cause"][cause] = {"n": int(len(g)), "survival": [round(float(x), 4) for x in shrink_curve(own, rel_all, len(g))]}
        sx = se.explode("routes").rename(columns={"routes": "route"})
        for route, g in sx[sx["route"].notna()].groupby("route"):
            if len(g) < min_n:
                continue
            own = km_survival(g["rel"].values, g["censored"].values, REL_GRID, entry_min=-g["stated_end_min"].values)
            out["relative"]["by_route"][route] = {"n": int(len(g)), "survival": [round(float(x), 4) for x in shrink_curve(own, rel_all, len(g))]}
    out["direction_share"] = ev["direction"].value_counts(normalize=True).round(3).to_dict()
    out["cause_share"] = ev["cause"].value_counts(normalize=True).round(3).to_dict()
    return out


# ---------------------------------------------------------------- recovery (staleness)

def _norm_name(s) -> str:
    if not isinstance(s, str):
        return ""
    return re.sub(r"[^a-z0-9]", "", s.lower().replace("–", "-"))


def station_stops(station, routes: list[str], direction: str, lines: dict, reach: int = 3) -> list[str]:
    """The stop ids on the alert's lines around the station it names (`reach` stops either side), in the direction
    it names or both. `lines` is the client schedule's table: "F_N" -> {"stops": [...], "names": [...]}."""
    if not isinstance(station, str) or not station or not lines:
        return []
    want = _norm_name(station)
    out: list[str] = []
    dirs = ["N", "S"] if direction not in ("N", "S") else [direction]
    for r in routes:
        for d in dirs:
            line = lines.get(f"{r}_{d}")
            if not line:
                continue
            names = [_norm_name(n) for n in line.get("names", [])]
            hit = next((i for i, n in enumerate(names) if n == want), None)
            if hit is None:
                hit = next((i for i, n in enumerate(names) if n.startswith(want) or want.startswith(n)), None)
            if hit is None:
                continue
            out.extend(line["stops"][max(0, hit - reach): hit + reach + 1])
    return sorted(set(out))


def stop_lateness_bins(matched: pd.DataFrame, bin_min: int = 10) -> pd.DataFrame:
    """Median lateness per route, stop and bin from schedule-matched arrivals."""
    m = matched.dropna(subset=["lateness_sec"]).copy()
    m = m[(m["lateness_sec"] > -600) & (m["lateness_sec"] < 5400)]
    m["bin"] = (m["arrival_ts"] // (bin_min * 60)).astype(int)
    m["route_id"] = m["route_id"].astype(str)
    g = m.groupby(["route_id", "stop_id", "bin"])["lateness_sec"].agg(["median", "size"]).reset_index()
    return g.rename(columns={"median": "lateness_sec", "size": "n"})


def route_lateness_bins(matched: pd.DataFrame, bin_min: int = 10) -> pd.DataFrame:
    """Median lateness per route per bin (the whole line)."""
    g = stop_lateness_bins(matched, bin_min)
    return g.groupby(["route_id", "bin"]).apply(lambda x: pd.Series({"lateness_sec": float(np.average(x["lateness_sec"], weights=x["n"])), "n": int(x["n"].sum())})).reset_index()


def recovery_lag(events: pd.DataFrame, bins: pd.DataFrame, windows: list[tuple[float, float]], bin_min: int = 10,
                 normal_margin_sec: float = 120.0, min_trains: int = 2, lines: dict | None = None, reach: int = 3,
                 quiet_before_min: int = 10) -> pd.DataFrame:
    """For each alert, when the feed first showed the stops around the named station (else the whole line) back
    within `normal_margin_sec` of their pre-alert lateness for two bins in a row, and how long the alert stayed
    posted after that. The baseline is the hour before the alert less its last `quiet_before_min` minutes, when the
    incident is usually already under way. Only measurable while the collector was polling."""
    rows = []
    bw = bin_min * 60
    bins = bins.copy()
    bins["route_id"] = bins["route_id"].astype(str)
    by_route = {r: g for r, g in bins.groupby("route_id")}
    for ev in events.itertuples(index=False):
        if not ev.routes:
            continue
        stops = station_stops(ev.station, ev.routes, ev.direction, lines or {}, reach)
        local = bool(stops)
        parts = []
        for r in ev.routes:
            g = by_route.get(r)
            if g is None:
                continue
            parts.append(g[g["stop_id"].isin(stops)] if local else g)
        if not parts:
            continue
        sel = pd.concat(parts)
        if sel.empty:
            continue
        per_bin = sel.groupby("bin").apply(lambda x: pd.Series({"lat": float(np.average(x["lateness_sec"], weights=x["n"])), "n": int(x["n"].sum())}))
        start_bin = int(ev.start_ts // bw)
        end_bin = int(ev.end_ts // bw)
        quiet = max(1, quiet_before_min // bin_min)
        base = per_bin.loc[(per_bin.index >= start_bin - 6) & (per_bin.index < start_bin - quiet + 1), "lat"]
        baseline = float(np.median(base)) if len(base) else 0.0
        recovered_bin = None
        prev_ok = False
        seen_delay = False
        for k in range(start_bin, end_bin + 1):
            if k not in per_bin.index or per_bin.loc[k, "n"] < min_trains:
                prev_ok = False
                continue
            late = float(per_bin.loc[k, "lat"]) > baseline + normal_margin_sec
            seen_delay = seen_delay or late
            ok = not late
            if ok and prev_ok:
                recovered_bin = k - 1
                break
            prev_ok = ok
        measured = recovered_bin is not None
        rec_ts = recovered_bin * bw if measured else None
        rows.append({"event_id": ev.event_id, "cause": ev.cause, "routes": ev.routes, "station": ev.station, "local": local,
                     "baseline_sec": baseline, "delay_seen": seen_delay,
                     "recovered_ts": rec_ts, "recovered_after_min": (rec_ts - ev.start_ts) / 60 if measured else None,
                     "lag_min": (ev.end_ts - rec_ts) / 60 if measured else None, "censored": bool(ev.censored),
                     "measured": measured})
    return pd.DataFrame(rows)


def stale_tables(rec: pd.DataFrame) -> dict:
    """How long alerts outlive the delay the feed can see, overall and by cause; the chance the alert is gone
    within 15 and 30 minutes of the feed looking normal; and how often the feed showed a delay at all."""
    out: dict = {"n_followed": int(len(rec)), "n_measured": int((rec["measured"] & rec["delay_seen"]).sum()) if len(rec) else 0}
    if len(rec):
        out["share_delay_seen"] = float(rec["delay_seen"].mean())
        out["share_local"] = float(rec["local"].mean())
        seen = rec[rec["delay_seen"]]
        out["n_delay_seen"] = int(len(seen))
    m = rec[rec["measured"] & rec["delay_seen"]] if len(rec) else rec
    if m.empty:
        return out
    def summary(g: pd.DataFrame) -> dict:
        lag = g["lag_min"].clip(lower=0)
        ended = ~g["censored"]
        return {"n": int(len(g)), "median_lag_min": float(lag.median()), "p75_lag_min": float(lag.quantile(0.75)),
                "share_removed_within_15": float(((lag <= 15) & ended).mean()),
                "share_removed_within_30": float(((lag <= 30) & ended).mean()),
                "median_recovery_min": float(g["recovered_after_min"].median())}
    out["all"] = summary(m)
    out["by_cause"] = {c: summary(g) for c, g in m.groupby("cause") if len(g) >= 4}
    return out


# ---------------------------------------------------------------- the published model

def build_model(tables: dict, stale: dict, generated_at: float, sources: dict) -> dict:
    keys = ("all", "by_route", "by_cause", "by_band", "by_route_cause", "by_station", "stated_end", "relative", "direction_share", "cause_share")
    return {"version": 1, "generated_at": generated_at, "sources": sources, "grid_min": tables.get("grid_min", GRID_MIN),
            "n_events": tables.get("n_events", 0), "n_ended": tables.get("n_ended", 0),
            "lifetime": {k: tables[k] for k in keys if k in tables}, "stale": stale}


def dumps(model: dict) -> str:
    return json.dumps(model, separators=(",", ":"), ensure_ascii=False)
