"""Can the feed see a delay before the MTA posts it? Slowdown episodes from the arrivals (consecutive trains losing
time on the same segment, as realtime/incidents.py watches for), matched to the delay alerts that followed, or
did not: how often an alert follows such a slowdown and how soon, how often a slowdown leads nowhere, and how often
an alert had a visible slowdown ahead of it. The tables feed the pre-warning in realtime/delay_service.py and the
app's DelayModel.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

from ..realtime.client_model import band_at

BIN_SEC = 300
WINDOW_SEC = 1200
MIN_TRAINS = 2
MIN_LOSS_SEC = 120.0
MIN_SHARE = 0.6
LOSS_BINS = [(120, 180, "2-3 min"), (180, 300, "3-5 min"), (300, 1e9, "5 min+")]
SHRINK_K = 20.0


def segment_losses(matched: pd.DataFrame) -> pd.DataFrame:
    """Per train and stop, the time lost since the previous stop: lateness here less lateness there."""
    m = matched.dropna(subset=["lateness_sec"]).copy()
    m = m[(m["lateness_sec"] > -600) & (m["lateness_sec"] < 7200)]
    m = m.sort_values(["trip_key", "arrival_ts"])
    g = m.groupby("trip_key")
    m["prev_stop"] = g["stop_id"].shift(1)
    m["prev_lat"] = g["lateness_sec"].shift(1)
    m["prev_ts"] = g["arrival_ts"].shift(1)
    m = m.dropna(subset=["prev_stop"])
    m = m[(m["arrival_ts"] - m["prev_ts"] > 0) & (m["arrival_ts"] - m["prev_ts"] < 1800)]
    m["delta"] = m["lateness_sec"] - m["prev_lat"]
    m["route_id"] = m["route_id"].astype(str)
    return m[["route_id", "direction", "prev_stop", "stop_id", "arrival_ts", "delta", "trip_key"]].reset_index(drop=True)


def slowdown_episodes(losses: pd.DataFrame, window_sec: float = WINDOW_SEC, min_trains: int = MIN_TRAINS,
                      min_loss_sec: float = MIN_LOSS_SEC, min_share: float = MIN_SHARE, bin_sec: int = BIN_SEC) -> pd.DataFrame:
    """Maximal runs of five-minute bins on one segment where, over the trailing window, at least `min_trains` trains
    and `min_share` of them lost `min_loss_sec` or more between the two stops."""
    cols = ["route_id", "direction", "from_stop", "to_stop", "start_ts", "end_ts", "onset_ts", "n_bins", "peak_loss_sec", "peak_n_slow", "peak_n", "band"]
    rows = []
    for (route, direction, prev, stop), g in losses.groupby(["route_id", "direction", "prev_stop", "stop_id"]):
        if len(g) < min_trains:
            continue
        ts = np.sort(g["arrival_ts"].values.astype(float))
        slow = g.sort_values("arrival_ts")["delta"].values >= min_loss_sec
        delta = g.sort_values("arrival_ts")["delta"].values
        if slow.sum() < min_trains:
            continue
        cum_slow = np.concatenate([[0], np.cumsum(slow)])
        cum_delta_slow = np.concatenate([[0], np.cumsum(np.where(slow, delta, 0.0))])
        t0 = np.floor(ts[0] / bin_sec) * bin_sec + bin_sec
        edges = np.arange(t0, ts[-1] + bin_sec, bin_sec)
        hi = np.searchsorted(ts, edges, side="right")
        lo = np.searchsorted(ts, edges - window_sec, side="right")
        n = hi - lo
        ns = cum_slow[hi] - cum_slow[lo]
        hold = (n >= min_trains) & (ns >= min_trains) & (ns / np.maximum(n, 1) >= min_share)
        i = 0
        while i < len(edges):
            if not hold[i]:
                i += 1
                continue
            j = i
            gap = 0
            while j + 1 < len(edges) and (hold[j + 1] or gap < 1):
                gap = 0 if hold[j + 1] else gap + 1
                j += 1
            while not hold[j]:
                j -= 1
            seg = slice(i, j + 1)
            mean_loss = np.where(ns[seg] > 0, (cum_delta_slow[hi[seg]] - cum_delta_slow[lo[seg]]) / np.maximum(ns[seg], 1), 0)
            k = int(np.argmax(mean_loss))
            onset = ts[lo[i]:hi[i]][slow[lo[i]:hi[i]]]
            rows.append({"route_id": route, "direction": direction, "from_stop": prev, "to_stop": stop,
                         "start_ts": float(edges[i]), "end_ts": float(edges[j]), "onset_ts": float(onset.min()) if onset.size else float(edges[i]),
                         "n_bins": int(j - i + 1), "peak_loss_sec": float(mean_loss[k]), "peak_n_slow": int(ns[seg][k]), "peak_n": int(n[seg][k]),
                         "band": band_at(float(edges[i]))})
            i = j + 1
    return pd.DataFrame(rows, columns=cols)


def label_episodes(episodes: pd.DataFrame, events: pd.DataFrame, horizon_min: float = 90.0) -> pd.DataFrame:
    """Each episode with: whether a delay alert on its line was already posted at its start (`covered`), the first
    alert on the line posted within `horizon_min` after it, the lead in minutes, and whether that came within 30
    and 60 minutes."""
    ep = episodes.copy()
    ev = events[events["routes"].map(len) > 0]
    by_route: dict[str, list[tuple[float, float, str]]] = {}
    for r in ev.itertuples(index=False):
        for route in r.routes:
            by_route.setdefault(str(route), []).append((float(r.start_ts), float(r.end_ts), r.event_id))
    covered, follow_id, lead = [], [], []
    for e in ep.itertuples(index=False):
        al = by_route.get(str(e.route_id), [])
        cov = any(s <= e.start_ts <= en for s, en, _ in al)
        later = sorted((s, i) for s, en, i in al if e.start_ts < s <= e.start_ts + horizon_min * 60)
        covered.append(cov)
        follow_id.append(later[0][1] if later else None)
        lead.append((later[0][0] - e.start_ts) / 60 if later else np.nan)
    ep["covered"] = covered
    ep["alert_id"] = follow_id
    ep["lead_min"] = lead
    ep["alert_within_30"] = ep["lead_min"] <= 30
    ep["alert_within_60"] = ep["lead_min"] <= 60
    return ep


def alert_leads(events: pd.DataFrame, episodes: pd.DataFrame, before_min: float = 60.0, after_min: float = 10.0) -> pd.DataFrame:
    """Each delay alert with the slowdown on its lines nearest before it (up to `before_min` before, or
    `after_min` after): the feed's lead on the alert, when it had one."""
    rows = []
    by_route = {r: g for r, g in episodes.groupby("route_id")}
    for ev in events.itertuples(index=False):
        best = None
        for route in ev.routes:
            g = by_route.get(str(route))
            if g is None:
                continue
            w = g[(g["onset_ts"] >= ev.start_ts - before_min * 60) & (g["onset_ts"] <= ev.start_ts + after_min * 60)]
            if len(w):
                s = float(w["onset_ts"].max()) if (w["onset_ts"] <= ev.start_ts).any() else float(w["onset_ts"].min())
                if (w["onset_ts"] <= ev.start_ts).any():
                    s = float(w.loc[w["onset_ts"] <= ev.start_ts, "onset_ts"].max())
                if best is None or abs(ev.start_ts - s) < abs(ev.start_ts - best):
                    best = s
        rows.append({"event_id": ev.event_id, "cause": ev.cause, "routes": ev.routes, "start_ts": ev.start_ts,
                     "slowdown_onset_ts": best, "lead_min": (ev.start_ts - best) / 60 if best is not None else np.nan})
    return pd.DataFrame(rows)


def base_rates(events: pd.DataFrame, episodes: pd.DataFrame, windows: list[tuple[float, float]]) -> dict:
    """What chance alone gives, per line, over the hours the collector was polling: the chance of a delay alert
    being posted in a random 30 or 60 minutes, and of a slowdown beginning in a random 30 or 60 minutes."""
    hours = sum(b - a for a, b in windows) / 3600 if windows else 0.0
    if hours <= 0:
        return {}
    n_alerts: dict[str, int] = {}
    for rs in events["routes"]:
        for r in rs:
            n_alerts[str(r)] = n_alerts.get(str(r), 0) + 1
    n_eps = episodes.groupby("route_id").size().to_dict() if len(episodes) else {}
    out = {}
    for r in set(n_alerts) | set(n_eps):
        la = n_alerts.get(r, 0) / hours
        le = n_eps.get(r, 0) / hours
        out[r] = {"alert_p30": float(1 - np.exp(-la * 0.5)), "alert_p60": float(1 - np.exp(-la)),
                  "slowdown_p30": float(1 - np.exp(-le * 0.5)), "slowdown_p60": float(1 - np.exp(-le))}
    return out


def _rate(g: pd.DataFrame, col: str) -> float | None:
    return float(g[col].mean()) if len(g) else None


def _shrunk(g: pd.DataFrame, col: str, prior: float, k: float = SHRINK_K) -> float:
    n = len(g)
    return float((g[col].sum() + prior * k) / (n + k))


def prewarn_tables(labeled: pd.DataFrame, leads: pd.DataFrame, min_n: int = 10, base: dict | None = None) -> dict:
    """The tables the pre-warning scores with: P(alert within 30/60 min of a slowdown that has no alert yet), by
    how much time the trains lost and how many of them, by line and by band, each beside what chance alone gives
    (`base`, from base_rates); the share of slowdowns that led to nothing; and the feed's lead on the alerts it
    saw coming, against the chance a slowdown would be there anyway."""
    out: dict = {"n_episodes": int(len(labeled))}
    if labeled.empty:
        return out
    base = base or {}
    open_ = labeled[~labeled["covered"]]
    out["n_open"] = int(len(open_))
    out["share_already_alerted"] = float(labeled["covered"].mean())
    p30, p60 = _rate(open_, "alert_within_30"), _rate(open_, "alert_within_60")
    # the baseline for the mix of lines the open slowdowns are on
    b30 = float(np.mean([base.get(str(r), {}).get("alert_p30", 0.0) for r in open_["route_id"]])) if base else None
    b60 = float(np.mean([base.get(str(r), {}).get("alert_p60", 0.0) for r in open_["route_id"]])) if base else None
    out["all"] = {"n": int(len(open_)), "p_alert_30": p30, "p_alert_60": p60, "base_p_alert_30": b30, "base_p_alert_60": b60,
                  "lift_30": (p30 / b30) if (p30 and b30) else None, "lift_60": (p60 / b60) if (p60 and b60) else None,
                  "median_lead_min": float(open_["lead_min"].median()) if open_["lead_min"].notna().any() else None}
    sev = []
    for lo, hi, name in LOSS_BINS:
        for trains, tname in ((2, "2 trains"), (3, "3+ trains")):
            g = open_[(open_["peak_loss_sec"] >= lo) & (open_["peak_loss_sec"] < hi) & ((open_["peak_n_slow"] >= 3) if trains == 3 else (open_["peak_n_slow"] == 2))]
            if len(g) >= 5:
                sev.append({"loss": name, "trains": tname, "loss_lo": lo, "min_trains": trains, "n": int(len(g)),
                            "p_alert_30": _shrunk(g, "alert_within_30", p30 or 0), "p_alert_60": _shrunk(g, "alert_within_60", p60 or 0)})
    out["by_severity"] = sev
    out["by_route"] = {r: {"n": int(len(g)), "p_alert_30": _shrunk(g, "alert_within_30", p30 or 0), "p_alert_60": _shrunk(g, "alert_within_60", p60 or 0),
                           "base_p_alert_30": base.get(str(r), {}).get("alert_p30")}
                       for r, g in open_.groupby("route_id") if len(g) >= min_n}
    out["by_band"] = {b: {"n": int(len(g)), "p_alert_30": _shrunk(g, "alert_within_30", p30 or 0), "p_alert_60": _shrunk(g, "alert_within_60", p60 or 0)}
                      for b, g in open_.groupby("band") if len(g) >= min_n}
    if len(leads):
        seen = leads[leads["lead_min"].notna()]
        ahead30 = leads[(leads["lead_min"] > 0) & (leads["lead_min"] <= 30)]
        ahead = leads[leads["lead_min"] > 0]
        # what chance gives: a slowdown beginning in the 30 (60) minutes before a random moment on the alert's lines
        def chance(key: str) -> float | None:
            if not base:
                return None
            vals = [max((base.get(str(r), {}).get(key, 0.0) for r in rs), default=0.0) for rs in leads["routes"]]
            return float(np.mean(vals)) if vals else None
        c30, c60 = chance("slowdown_p30"), chance("slowdown_p60")
        s30 = float(len(ahead30) / len(leads))
        s60 = float(len(ahead) / len(leads))
        out["leads"] = {"n_alerts": int(len(leads)), "share_with_slowdown": float(len(seen) / len(leads)),
                        "share_feed_first_30": s30, "share_feed_first_60": s60, "chance_30": c30, "chance_60": c60,
                        "lift_30": (s30 / c30) if c30 else None, "lift_60": (s60 / c60) if c60 else None,
                        "median_lead_min": float(ahead["lead_min"].median()) if len(ahead) else None,
                        "p25_lead_min": float(ahead["lead_min"].quantile(0.25)) if len(ahead) else None,
                        "by_cause": {c: {"n": int(len(g)), "share_feed_first_30": float(((g["lead_min"] > 0) & (g["lead_min"] <= 30)).mean()),
                                         "median_lead_min": float(g.loc[g["lead_min"] > 0, "lead_min"].median()) if (g["lead_min"] > 0).any() else None}
                                     for c, g in leads.groupby("cause") if len(g) >= 8}}
    return out


def score_slowdown(model_prewarn: dict, route: str, loss_sec: float, n_slow: int, band: str | None = None) -> tuple[float, float, float, str]:
    """P(alert within 30 and 60 min) for a slowdown with no alert yet, the lift over chance of the 30-minute figure,
    and the basis in words. From the station-local severity table (an alert naming a stop near the segment, against
    chance) when the model has it; else the line-level table nudged by the line's own rate, with a lift of 1."""
    loc = (model_prewarn.get("local") or {}).get("from_slowdowns") or {}
    if loc:
        p30, p60, lift, basis = loc.get("p_alert_30", 0.0), loc.get("p_alert_60", 0.0), loc.get("lift_30") or 1.0, "all slowdowns, an alert nearby"
        best = None
        for row in loc.get("by_severity", []):
            if loss_sec >= row["loss_lo"] and (n_slow >= 3 if row["min_trains"] == 3 else n_slow == 2):
                if best is None or row["loss_lo"] >= best["loss_lo"]:
                    best = row
        if best:
            p30, p60, lift, basis = best["p_alert_30"], best["p_alert_60"], best.get("lift_30") or 1.0, f"{best['trains']} losing {best['loss']}, an alert nearby"
        return float(p30), float(p60), float(lift), basis
    base30 = (model_prewarn.get("all") or {}).get("p_alert_30") or 0.0
    base60 = (model_prewarn.get("all") or {}).get("p_alert_60") or 0.0
    p30, p60, basis = base30, base60, "all slowdowns on the line"
    best = None
    for row in model_prewarn.get("by_severity", []):
        if loss_sec >= row["loss_lo"] and (n_slow >= 3 if row["min_trains"] == 3 else n_slow == 2):
            if best is None or row["loss_lo"] >= best["loss_lo"]:
                best = row
    if best:
        p30, p60, basis = best["p_alert_30"], best["p_alert_60"], f"{best['trains']} losing {best['loss']}"
    r = (model_prewarn.get("by_route") or {}).get(route)
    if r and base30:
        f = r["p_alert_30"] / base30
        p30 = min(0.98, p30 * (0.5 + 0.5 * f))
        p60 = min(0.98, p60 * (0.5 + 0.5 * (r["p_alert_60"] / base60 if base60 else 1)))
        basis += f", the {route}"
    return float(p30), float(p60), 1.0, basis


def _hours_in(windows: list[tuple[float, float]], lo: float, hi: float) -> float:
    return sum(max(0.0, min(b, hi) - max(a, lo)) for a, b in windows) / 3600


def local_tables(events: pd.DataFrame, episodes: pd.DataFrame, lines: dict, windows: list[tuple[float, float]],
                 reach: int = 3, before_min: float = 30.0, horizon_min: float = 60.0) -> dict:
    """The station-local test, both ways, against chance. The line-level test is too coarse: lines are long and the
    network sees dozens of slowdowns an hour, so a slowdown somewhere on the line is nearly always there.

    Seen from the alerts that name a station the schedule knows: was a slowdown on their lines within `reach` stops
    of that station under way when the alert was posted, and did one begin in the `before_min` before it, against the
    chance such a slowdown begins in a random `before_min` on that stretch (its own rate over the polling hours).

    Seen from the slowdowns: did a delay alert naming a station within `reach` stops of the segment follow within 30
    or 60 min, against the chance of one in a random such window, by severity."""
    from .delay_lifecycle import station_stops
    if episodes.empty or not lines:
        return {}
    lo, hi = float(episodes["onset_ts"].min()), float(episodes["end_ts"].max())
    hours = _hours_in(windows, lo, hi)
    if hours <= 0:
        return {}
    ev = events[(events["start_ts"] >= lo) & (events["start_ts"] <= hi)].copy()
    ev = ev[ev["station"].map(lambda s: isinstance(s, str) and bool(s))]
    stops_of = {r.event_id: set(station_stops(r.station, list(r.routes), r.direction, lines, reach=reach)) for r in ev.itertuples(index=False)}
    ev = ev[ev["event_id"].map(lambda i: len(stops_of[i]) > 0)]
    out: dict = {"reach": reach, "hours": float(hours), "n_alerts_with_station": int(len(ev))}
    if ev.empty:
        return out
    ep_by_route = {r: g for r, g in episodes.groupby("route_id")}

    # from the alerts: the slowdowns near the station they name
    rows = []
    for r in ev.itertuples(index=False):
        stops = stops_of[r.event_id]
        parts = []
        for route in r.routes:
            g = ep_by_route.get(str(route))
            if g is not None:
                parts.append(g[g["from_stop"].isin(stops) | g["to_stop"].isin(stops)])
        near = pd.concat(parts) if parts else episodes.iloc[0:0]
        began = near[(near["onset_ts"] >= r.start_ts - before_min * 60) & (near["onset_ts"] <= r.start_ts)]
        under_way = near[(near["onset_ts"] <= r.start_ts) & (near["end_ts"] >= r.start_ts)]
        rate = len(near) / hours
        rows.append({"event_id": r.event_id, "cause": r.cause, "n_near": int(len(near)), "began_before": bool(len(began)),
                     "under_way": bool(len(under_way)), "chance": float(1 - np.exp(-rate * before_min / 60)),
                     "lead_min": float((r.start_ts - began["onset_ts"].max()) / 60) if len(began) else np.nan})
    la = pd.DataFrame(rows)
    s, c = float(la["began_before"].mean()), float(la["chance"].mean())
    ahead = la[la["lead_min"].notna()]
    out["from_alerts"] = {"n": int(len(la)), "slowdown_under_way": float(la["under_way"].mean()), "began_in_before": s,
                          "before_min": before_min, "chance": c, "lift": (s / c) if c else None,
                          "median_lead_min": float(ahead["lead_min"].median()) if len(ahead) else None,
                          "by_cause": {k: {"n": int(len(g)), "slowdown_under_way": float(g["under_way"].mean()),
                                           "began_in_before": float(g["began_before"].mean()), "chance": float(g["chance"].mean())}
                                       for k, g in la.groupby("cause") if len(g) >= 8}}

    # from the slowdowns: the alerts naming a station near their segment
    al_by_route: dict[str, list] = {}
    for r in ev.itertuples(index=False):
        for route in r.routes:
            al_by_route.setdefault(str(route), []).append((float(r.start_ts), float(r.end_ts), r.event_id, stops_of[r.event_id]))
    rows = []
    for e in episodes.itertuples(index=False):
        al = [(s0, en) for s0, en, _, st in al_by_route.get(str(e.route_id), []) if e.from_stop in st or e.to_stop in st]
        cov = any(s0 <= e.onset_ts <= en for s0, en in al)
        later = sorted(s0 for s0, en in al if e.onset_ts < s0 <= e.onset_ts + horizon_min * 60)
        rate = len(al) / hours
        rows.append({"route_id": e.route_id, "band": e.band, "peak_loss_sec": e.peak_loss_sec, "peak_n_slow": e.peak_n_slow, "covered": cov,
                     "lead_min": (later[0] - e.onset_ts) / 60 if later else np.nan,
                     "chance_30": float(1 - np.exp(-rate * 0.5)), "chance_60": float(1 - np.exp(-rate))})
    le = pd.DataFrame(rows)
    le["alert_within_30"] = le["lead_min"] <= 30
    le["alert_within_60"] = le["lead_min"] <= 60
    open_ = le[~le["covered"]]

    def block(g: pd.DataFrame) -> dict:
        p30, p60 = float(g["alert_within_30"].mean()), float(g["alert_within_60"].mean())
        c30, c60 = float(g["chance_30"].mean()), float(g["chance_60"].mean())
        return {"n": int(len(g)), "p_alert_30": p30, "chance_30": c30, "lift_30": (p30 / c30) if c30 else None,
                "p_alert_60": p60, "chance_60": c60, "lift_60": (p60 / c60) if c60 else None}

    sev = []
    for lo_s, hi_s, label in LOSS_BINS:
        for min_trains, trains in ((2, "2 trains"), (3, "3+ trains")):
            g = open_[(open_["peak_loss_sec"] >= lo_s) & (open_["peak_loss_sec"] < hi_s)
                      & ((open_["peak_n_slow"] >= 3) if min_trains == 3 else (open_["peak_n_slow"] == 2))]
            if len(g) >= 10:
                sev.append({"loss": label, "loss_lo": lo_s, "trains": trains, "min_trains": min_trains, **block(g)})
    out["from_slowdowns"] = {"n_open": int(len(open_)), "share_already_alerted": float(le["covered"].mean()), **block(open_), "by_severity": sev,
                            "by_route": {r: block(g) for r, g in open_.groupby("route_id") if len(g) >= 30}}
    return out
