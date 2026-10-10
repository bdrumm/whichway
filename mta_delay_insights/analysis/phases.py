"""The phases of a delay alert as the feed tells them: starting, in effect, waning, stale.

An alert is a message; the trains are the fact. For each unplanned delay alert the feed gives a trajectory: the
lateness of arrivals, per five minutes, at the stops around the station it names (the whole line when it names
none), as excess over the hour before the alert. Read along that trajectory with only what was knowable at each
moment, the alert is

- starting: posted, nothing over the margin in the feed yet, and not yet past the time by which alerts that will
  show in the feed have shown (`never_min`, the upper quartile of the lag from posting to first evidence);
- in effect: the feed shows the delay (excess at or over the margin) and it is not receding;
- waning: the delay is receding (under half its peak) or the stops have just come back under the margin;
- stale: the stops have read normal for `stale_bins` bins after a delay the feed saw;
- unconfirmed: past `never_min` with nothing in the feed, ever (many alerts never register in the arrivals: a
  delay too local or too brief, or one the alert overstated) — the calibration says how such alerts end.

`calibrate` labels every bin of every alert the collector could follow and reports, per phase, how often the alert
was gone 15, 30 and 60 minutes later: the baseline the realtime score assumes for a new alert, with the trains'
statuses on the line to corroborate. `phase_now` applies the same rules live, on the server (from the store's
arrivals since posting) and, approximately, on the phone (from the boards and the lateness it has seen).
"""
from __future__ import annotations

import numpy as np
import pandas as pd

from .delay_lifecycle import station_stops, stop_lateness_bins

BIN_MIN = 5
MARGIN_SEC = 120.0        # excess over the pre-alert baseline that reads as the delay
RECEDE = 0.5              # under this share of the peak excess, the delay is receding
STALE_BINS = 2            # bins back under the margin, after a delay the feed saw, before the alert reads stale
PRE_MIN = 60              # the baseline: the hour before the alert ...
QUIET_MIN = 10            # ... less its last ten minutes, when the incident is usually under way
POST_MIN = 60             # follow the trajectory this long past the alert's end
MIN_TRAINS = 2            # a bin with fewer arrivals says nothing
PHASES = ("starting", "in effect", "waning", "stale", "unconfirmed")
PRIORITY = {"in effect": 0, "starting": 1, "waning": 2, "unconfirmed": 3, "stale": 4}
DEFAULT_START_MIN = 10.0
DEFAULT_NEVER_MIN = 30.0


# ------------------------------------------------------------------ trajectories

def trajectory(bins: pd.DataFrame, start_ts: float, end_ts: float, routes: list[str], stops: list[str] | None,
               bin_min: int = BIN_MIN) -> pd.DataFrame:
    """Per bin from an hour before the alert to an hour after its end: minutes since posting, the arrivals' median
    lateness (weighted over the stops), its excess over the pre-alert baseline, and how many arrivals stood behind it.
    `bins` is stop_lateness_bins() on the matched arrivals; `stops` narrows it to the station's stretch."""
    bw = bin_min * 60
    sel = bins[bins["route_id"].astype(str).isin([str(r) for r in routes])]
    if stops:
        sel = sel[sel["stop_id"].isin(stops)]
    lo, hi = int((start_ts - PRE_MIN * 60) // bw), int((end_ts + POST_MIN * 60) // bw)
    sel = sel[(sel["bin"] >= lo) & (sel["bin"] <= hi)]
    if sel.empty:
        return pd.DataFrame(columns=["bin", "ts", "age_min", "lateness_sec", "excess_sec", "n"])
    per = sel.groupby("bin").apply(lambda x: pd.Series({"lateness_sec": float(np.average(x["lateness_sec"], weights=x["n"])), "n": int(x["n"].sum())}))
    per = per.reset_index()
    per["ts"] = per["bin"] * bw
    per["age_min"] = (per["ts"] - start_ts) / 60
    base = per[(per["age_min"] >= -PRE_MIN) & (per["age_min"] < -QUIET_MIN) & (per["n"] >= MIN_TRAINS)]["lateness_sec"]
    baseline = float(base.median()) if len(base) else 0.0
    per["excess_sec"] = per["lateness_sec"] - baseline
    per.attrs["baseline_sec"] = baseline
    return per[["bin", "ts", "age_min", "lateness_sec", "excess_sec", "n"]]


def trajectories(events: pd.DataFrame, matched: pd.DataFrame, lines: dict, reach: int = 3, bin_min: int = BIN_MIN) -> dict[str, pd.DataFrame]:
    """One trajectory per alert the arrivals can follow, station-local where the schedule knows the station."""
    bins = stop_lateness_bins(matched, bin_min)
    bins["route_id"] = bins["route_id"].astype(str)
    out: dict[str, pd.DataFrame] = {}
    for ev in events.itertuples(index=False):
        if not ev.routes:
            continue
        stops = station_stops(ev.station, list(ev.routes), ev.direction, lines or {}, reach)
        t = trajectory(bins, float(ev.start_ts), float(ev.end_ts), list(ev.routes), stops or None, bin_min)
        if len(t):
            t.attrs["local"] = bool(stops)
            out[ev.event_id] = t
    return out


# ------------------------------------------------------------------ the rules

def phase_now(age_min: float, excess_sec: float | None, seen: bool, peak_excess_sec: float, recovered_min: float | None,
              start_min: float = DEFAULT_START_MIN, never_min: float = DEFAULT_NEVER_MIN, margin_sec: float = MARGIN_SEC,
              recede: float = RECEDE, stale_min: float = STALE_BINS * BIN_MIN) -> str:
    """The phase from what is knowable now: the alert's age, the feed's excess now (None: no reading), whether the
    feed has shown the delay at any point, the peak excess so far, and how long the stops have read normal since."""
    if excess_sec is not None and excess_sec >= margin_sec:
        return "in effect" if excess_sec >= recede * peak_excess_sec else "waning"
    if seen:
        # a delay the feed saw, now under the margin (or no reading this bin): just recovered, then stale
        if recovered_min is None or recovered_min < stale_min:
            return "waning"
        return "stale"
    return "starting" if age_min < never_min else "unconfirmed"


def label_trajectory(t: pd.DataFrame, start_min: float, never_min: float, margin_sec: float = MARGIN_SEC) -> pd.DataFrame:
    """The phase at every bin of an alert's life, reading the trajectory forward with only its past."""
    rows = []
    seen = False
    peak = 0.0
    recovered_since: float | None = None
    for r in t.itertuples(index=False):
        if r.age_min < 0:
            continue
        ex = float(r.excess_sec) if r.n >= MIN_TRAINS else None
        if ex is not None and ex >= margin_sec:
            seen = True
            peak = max(peak, ex)
            recovered_since = None
        elif ex is not None and seen and recovered_since is None:
            recovered_since = float(r.ts)
        rec_min = (float(r.ts) - recovered_since) / 60 if recovered_since is not None else None
        rows.append({"bin": r.bin, "ts": r.ts, "age_min": r.age_min, "excess_sec": ex, "n": r.n, "seen": seen, "peak_excess_sec": peak,
                     "recovered_min": rec_min, "phase": phase_now(float(r.age_min), ex, seen, peak, rec_min, start_min, never_min, margin_sec)})
    return pd.DataFrame(rows)


# ------------------------------------------------------------------ calibration

def _q(s: pd.Series, p: float) -> float | None:
    return float(s.quantile(p)) if len(s) else None


def calibrate(events: pd.DataFrame, matched: pd.DataFrame, lines: dict, windows: list[tuple[float, float]],
              reach: int = 3, min_n: int = 8) -> dict:
    """The tables: when the feed first shows an alert's delay (which sets `start_min` and `never_min`), the peak
    and the recovery, each phase's share of alert-minutes and the chance the alert is gone 15, 30 and 60 minutes
    later, by cause, and the baseline for a new alert by what the trains showed at posting."""
    trajs = trajectories(events, matched, lines, reach)
    out: dict = {"bin_min": BIN_MIN, "margin_sec": MARGIN_SEC, "recede": RECEDE, "stale_min": STALE_BINS * BIN_MIN, "n_followed": len(trajs)}
    if not trajs:
        return out
    ev_by_id = {r.event_id: r for r in events.itertuples(index=False)}

    # first evidence, the peak and the recovery, per alert
    first_rows = []
    for eid, t in trajs.items():
        ev = ev_by_id[eid]
        life = t[(t["age_min"] >= 0) & (t["ts"] <= ev.end_ts) & (t["n"] >= MIN_TRAINS)]
        shown = life[life["excess_sec"] >= MARGIN_SEC]
        at_posting = t[(t["age_min"] >= -BIN_MIN) & (t["age_min"] < BIN_MIN) & (t["n"] >= MIN_TRAINS)]
        under_way = bool(len(at_posting)) and bool((at_posting["excess_sec"] >= MARGIN_SEC).any())
        row = {"event_id": eid, "cause": ev.cause, "local": bool(t.attrs.get("local")), "censored": bool(ev.censored),
               "duration_min": (ev.end_ts - ev.start_ts) / 60, "seen": bool(len(shown)), "under_way_at_posting": under_way,
               "first_min": float(shown["age_min"].min()) if len(shown) else None, "n_bins": int(len(life))}
        if len(shown):
            pk = shown.loc[shown["excess_sec"].idxmax()]
            row["peak_min"] = float(pk["age_min"])
            row["peak_excess_sec"] = float(pk["excess_sec"])
            after = life[(life["age_min"] > pk["age_min"]) & (life["excess_sec"] < MARGIN_SEC)]
            row["recovery_min"] = float(after["age_min"].min()) if len(after) else None
        first_rows.append(row)
    fr = pd.DataFrame(first_rows)
    followed = fr[fr["n_bins"] >= 2]
    seen = followed[followed["seen"]]
    lag = seen["first_min"].clip(lower=0)
    start_min = float(min(20, max(10, _q(lag, 0.5) or DEFAULT_START_MIN)))
    never_min = float(min(45, max(20, _q(lag, 0.75) or DEFAULT_NEVER_MIN)))
    out["evidence"] = {"n": int(len(followed)), "share_seen_ever": float(followed["seen"].mean()) if len(followed) else None,
                       "share_under_way_at_posting": float(followed["under_way_at_posting"].mean()) if len(followed) else None,
                       "share_seen_within_10": float((seen["first_min"] <= 10).sum() / max(1, len(followed))),
                       "share_seen_within_20": float((seen["first_min"] <= 20).sum() / max(1, len(followed))),
                       "share_seen_within_30": float((seen["first_min"] <= 30).sum() / max(1, len(followed))),
                       "first_evidence_min": {"p25": _q(lag, 0.25), "p50": _q(lag, 0.5), "p75": _q(lag, 0.75)},
                       "start_min": start_min, "never_min": never_min, "share_local": float(followed["local"].mean()) if len(followed) else None}
    pk = seen.dropna(subset=["peak_min"])
    rc = pk.dropna(subset=["recovery_min"])
    out["peak"] = {"n": int(len(pk)), "minutes_to_peak_p50": _q(pk["peak_min"], 0.5), "peak_excess_sec_p50": _q(pk["peak_excess_sec"], 0.5),
                   "minutes_to_recovery_p50": _q(rc["recovery_min"], 0.5), "minutes_peak_to_recovery_p50": _q(rc["recovery_min"] - rc["peak_min"], 0.5),
                   "share_recovered_while_posted": float(len(rc) / len(pk)) if len(pk) else None}

    # every bin labeled, and how the alert went from there
    labeled = []
    poll_end = {}
    for eid, t in trajs.items():
        ev = ev_by_id[eid]
        lab = label_trajectory(t[t["ts"] <= ev.end_ts], start_min, never_min)
        if lab.empty:
            continue
        lab["event_id"] = eid
        lab["cause"] = ev.cause
        lab["end_ts"] = ev.end_ts
        lab["censored"] = bool(ev.censored)
        labeled.append(lab)
    if not labeled:
        return out
    L = pd.concat(labeled, ignore_index=True)
    for h in (15, 30, 60):
        remaining = (L["end_ts"] - L["ts"]) / 60
        gone = remaining < h
        known = (~gone) | (~L["censored"])          # still up at the horizon, or an end the collector saw
        L[f"gone_{h}"] = np.where(known, gone.astype(float), np.nan)

    def block(g: pd.DataFrame) -> dict:
        d = {"n_bins": int(len(g)), "n_alerts": int(g["event_id"].nunique()), "share_of_minutes": float(len(g) / len(L)),
             "median_age_min": float(g["age_min"].median())}
        for h in (15, 30, 60):
            v = g[f"gone_{h}"].dropna()
            d[f"p_gone_{h}"] = float(v.mean()) if len(v) >= min_n else None
            d[f"n_gone_{h}"] = int(len(v))
        return d

    out["by_phase"] = {p: block(L[L["phase"] == p]) for p in PHASES if (L["phase"] == p).any()}
    # the phase at ages: what a rider sees most at each point of an alert's life
    L["age_band"] = pd.cut(L["age_min"], [0, 10, 20, 30, 60, 120, 1e9], right=False, labels=["0-10", "10-20", "20-30", "30-60", "60-120", "120+"])
    out["phase_by_age"] = {str(b): {p: float((g["phase"] == p).mean()) for p in PHASES} | {"n_bins": int(len(g))}
                           for b, g in L.groupby("age_band", observed=True)}
    by_cause = {}
    for c, g in L.groupby("cause"):
        f = followed[followed["cause"] == c]
        if len(f) < 5:
            continue
        s = f[f["seen"]]
        by_cause[c] = {"n_alerts": int(len(f)), "share_seen_ever": float(f["seen"].mean()),
                       "first_evidence_min_p50": _q(s["first_min"].clip(lower=0), 0.5),
                       "phases": {p: block(g[g["phase"] == p]) for p in PHASES if (g["phase"] == p).sum() >= min_n}}
    out["by_cause"] = by_cause
    # a new alert: what to assume from the trains at posting
    fresh = L[L["age_min"] < start_min]
    new = {}
    for key, cond in (("trains_late_at_posting", followed["under_way_at_posting"]), ("trains_normal_at_posting", ~followed["under_way_at_posting"])):
        f = followed[cond]
        if f.empty:
            continue
        ids = set(f["event_id"])
        g = fresh[fresh["event_id"].isin(ids)]
        ended = f[~f["censored"]]
        new[key] = {"n": int(len(f)), "share_seen_ever": float(f["seen"].mean()), "median_lifetime_min": _q(ended["duration_min"], 0.5),
                    "p_gone_30_at_start": float(g["gone_30"].dropna().mean()) if g["gone_30"].notna().sum() >= min_n else None,
                    "p_gone_60_at_start": float(g["gone_60"].dropna().mean()) if g["gone_60"].notna().sum() >= min_n else None}
    out["new_alert"] = new
    return out


# ------------------------------------------------------------------ realtime

def summarize_trajectory(t: pd.DataFrame, now: float, start_min: float, never_min: float) -> dict:
    """What the realtime score needs from an alert's trajectory up to now: the phase, the feed's excess now, the
    peak so far and when, how long the stops have read normal, and the baseline."""
    lab = label_trajectory(t[t["ts"] <= now], start_min, never_min)
    if lab.empty:
        return {"phase": None}
    last = lab.iloc[-1]
    readings = lab.dropna(subset=["excess_sec"])
    pk = readings.loc[readings["excess_sec"].idxmax()] if len(readings) else None
    return {"phase": str(last["phase"]), "age_min": float(last["age_min"]), "excess_now_sec": None if pd.isna(last["excess_sec"]) else float(last["excess_sec"]),
            "n_now": int(last["n"]), "seen": bool(last["seen"]), "peak_excess_sec": float(last["peak_excess_sec"]),
            "peak_age_min": float(pk["age_min"]) if pk is not None and float(last["peak_excess_sec"]) > 0 else None,
            "recovered_min": None if pd.isna(last["recovered_min"]) else float(last["recovered_min"]),
            "baseline_sec": float(t.attrs.get("baseline_sec", 0.0)), "local": bool(t.attrs.get("local", False)),
            "bins": [{"age_min": round(float(r.age_min)), "excess_sec": None if r.n < MIN_TRAINS else round(float(r.excess_sec)), "n": int(r.n)}
                     for r in t[t["ts"] <= now].itertuples(index=False)][-24:]}
