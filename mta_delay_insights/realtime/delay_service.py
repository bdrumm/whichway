"""Score the delay alerts in the feed right now against the lifecycle model: when each was posted and where, how
likely it is to be gone soon, and whether the feed still bears it out (see analysis/delay_lifecycle.py and
docs/delay_model_report.md).

    assess_alerts(alerts_now, model, now, feed={"F": {"lateness_sec": 240, "n_trains": 9, "n_held": 1}, ...})

`feed` is what the boards say per route at `now`: the median lateness of its trains in service and how many are
held or overdue. Without it the score rests on the curves alone.
"""
from __future__ import annotations

import time

import numpy as np
import pandas as pd

from ..analysis.delay_lifecycle import extract_direction, extract_station
from ..sources.alerts import alert_kind, classify_cause

NORMAL_LATENESS_SEC = 120.0      # a line whose trains run within two minutes of the timetable reads as normal
MIN_GROUP_N = 8
CAUSE_WORDS = {
    "rolling_stock": "a train problem", "signal": "signal problems", "switch": "a switch problem", "track": "track work or a track condition",
    "medical": "a medical call", "police": "police activity", "person_on_track": "a person on the track", "fire_smoke": "fire or smoke",
    "power": "a power problem", "obstruction": "an obstruction", "water_weather": "weather", "crowding_dwell": "crowding",
    "crew": "crew availability", "reduced_service": "reduced service", "planned_work": "work on the line", "investigation": "an investigation",
    "unknown": "an unstated cause",
}


def _interp(curve: list[float], grid_start: float, step: float, t: float) -> float:
    """S(t) from a grid curve, linearly between points, held at the ends."""
    if not curve:
        return 1.0
    x = (t - grid_start) / step
    if x <= 0:
        return float(curve[0])
    if x >= len(curve) - 1:
        return float(curve[-1])
    i = int(x)
    f = x - i
    return float(curve[i] * (1 - f) + curve[i + 1] * f)


def _pick(model: dict, routes: list[str], cause: str, relative: bool) -> tuple[list[float], float, str]:
    """The most specific curve with enough behind it: route×cause, cause, route, all. Returns (curve, grid start, name)."""
    L = model.get("lifetime", {})
    step = float(model.get("grid_min", 10))
    if relative:
        R = L.get("relative", {})
        start = float(R.get("grid_start", -120))
        for r in routes:
            g = R.get("by_route", {}).get(r)
            cg = R.get("by_cause", {}).get(cause)
            if cg and cg.get("n", 0) >= MIN_GROUP_N:
                return cg["survival"], start, f"cause {cause}"
            if g and g.get("n", 0) >= MIN_GROUP_N:
                return g["survival"], start, f"line {r}"
        cg = R.get("by_cause", {}).get(cause)
        if cg and cg.get("n", 0) >= MIN_GROUP_N:
            return cg["survival"], start, f"cause {cause}"
        return R.get("all", {}).get("survival", []), start, "all alerts"
    for r in routes:
        g = L.get("by_route_cause", {}).get(f"{r}|{cause}")
        if g and g.get("n", 0) >= MIN_GROUP_N:
            return g["survival"], 0.0, f"line {r}, {cause}"
    g = L.get("by_cause", {}).get(cause)
    if g and g.get("n", 0) >= MIN_GROUP_N:
        return g["survival"], 0.0, f"cause {cause}"
    for r in routes:
        g = L.get("by_route", {}).get(r)
        if g and g.get("n", 0) >= MIN_GROUP_N:
            return g["survival"], 0.0, f"line {r}"
    return L.get("all", {}).get("survival", []), 0.0, "all alerts"


def clear_probabilities(curve: list[float], grid_start: float, step: float, t: float, horizons=(15, 30, 60)) -> tuple[dict, float]:
    """P(gone within h | still posted at t) for each horizon, and the expected remaining minutes (capped at the grid)."""
    s0 = max(_interp(curve, grid_start, step, t), 0.02)
    probs = {h: float(max(0.0, min(1.0, 1 - _interp(curve, grid_start, step, t + h) / s0))) for h in horizons}
    end = grid_start + step * (len(curve) - 1)
    ts = np.arange(t, end + 1e-9, 1.0)
    if ts.size < 2:
        return probs, 0.0
    cond = np.array([_interp(curve, grid_start, step, x) / s0 for x in ts])
    expected = float(np.trapezoid(np.minimum(cond, 1.0), ts)) if hasattr(np, "trapezoid") else float(np.trapz(np.minimum(cond, 1.0), ts))
    return probs, expected


def assess_alert(a: dict, model: dict, now: float, feed: dict | None = None) -> dict:
    routes = [str(r) for r in (a.get("routes") or [])]
    header = a.get("header") or ""
    cause = a.get("cause_category") or classify_cause(header)
    created = float(a.get("created_at") or a.get("active_start") or now)
    age = max(0.0, (now - created) / 60.0)
    stated_end = a.get("active_end")
    stated_end = float(stated_end) if stated_end is not None and not (isinstance(stated_end, float) and np.isnan(stated_end)) and float(stated_end) > created else None
    step = float(model.get("grid_min", 10))
    if stated_end is not None:
        rel = (now - stated_end) / 60.0
        curve, start, basis = _pick(model, routes, cause, relative=True)
        probs, expected = clear_probabilities(curve, start, step, rel)
    else:
        curve, start, basis = _pick(model, routes, cause, relative=False)
        probs, expected = clear_probabilities(curve, start, step, age)

    # the feed now, on the alert's lines
    late = held = n = 0.0
    seen = False
    if feed:
        vals = [feed[r] for r in routes if r in feed]
        if vals:
            seen = True
            n = sum(float(v.get("n_trains", 0)) for v in vals)
            held = sum(float(v.get("n_held", 0)) for v in vals)
            late = float(np.median([float(v.get("lateness_sec", 0)) for v in vals]))
    feed_normal = seen and n >= 2 and late < NORMAL_LATENESS_SEC and held == 0
    feed_active = seen and (late >= NORMAL_LATENESS_SEC or held > 0)

    stale_tab = model.get("stale", {})
    gone_after_recovery = (stale_tab.get("by_cause", {}).get(cause) or stale_tab.get("all") or {}).get("share_removed_within_30")
    # the chance the alert is stale now: the feed looks normal and alerts like it are usually gone soon after that
    if feed_normal:
        stale = max(probs[30], gone_after_recovery or 0.0) if age >= 10 else probs[30]
    elif feed_active:
        stale = min(probs[30], 0.25)
    else:
        stale = probs[30]
    if age < 10:
        status = "fresh"
    elif feed_active:
        status = "active"
    elif age >= 240 and feed_normal:
        status = "standing"
    elif stale >= 0.5:
        status = "likely stale"
    else:
        status = "aging"

    station = extract_station(header)
    direction = extract_direction(header)
    where = (station + " · " if station else "") + "/".join(routes) + {"N": " uptown", "S": " downtown", "both": " both ways", "unknown": ""}[direction]
    posted = time.strftime("%-H:%M", time.localtime(created))
    bits = [f"{CAUSE_WORDS.get(cause, cause)} on the {'/'.join(routes)}" + (f" at {station}" if station else ""),
            f"posted {posted} ({age:.0f} min ago)"]
    if stated_end is not None:
        bits.append(f"MTA's end {time.strftime('%-H:%M', time.localtime(stated_end))}" + (" passed" if now > stated_end else ""))
    bits.append(f"{probs[30]:.0%} gone within 30 min")
    if seen:
        bits.append("trains on time now" if late < NORMAL_LATENESS_SEC else f"trains {late / 60:.0f} min late" + (f", {int(held)} held" if held else ""))
    return {
        "alert_id": a.get("alert_id"), "routes": routes, "cause": cause, "kind": alert_kind(a.get("alert_type"), header),
        "station": station, "direction": direction, "where": where, "posted_ts": created, "age_min": round(age, 1),
        "stated_end_ts": stated_end, "p_clear_15": round(probs[15], 3), "p_clear_30": round(probs[30], 3), "p_clear_60": round(probs[60], 3),
        "expected_remaining_min": round(expected, 1), "basis": basis,
        "feed": {"seen": seen, "lateness_sec": round(late), "n_trains": int(n), "n_held": int(held)},
        "stale_score": round(float(stale), 3), "status": status, "text": " · ".join(bits) + f" → {status}",
    }


def assess_alerts(alerts_now: pd.DataFrame | list[dict], model: dict, now: float | None = None, feed: dict | None = None) -> list[dict]:
    now = now or time.time()
    rows = alerts_now.to_dict(orient="records") if isinstance(alerts_now, pd.DataFrame) else list(alerts_now)
    out = []
    for a in rows:
        if alert_kind(a.get("alert_type"), a.get("header") or "") != "delay":
            continue
        if "delay" not in str(a.get("alert_type") or "").lower():
            continue
        if set(str(r) for r in (a.get("routes") or [])) <= {"SI"}:
            continue
        out.append(assess_alert(a, model, now, feed))
    out.sort(key=lambda x: (x["status"] == "standing", x["stale_score"], -x["age_min"]))
    return out


def prewarnings(matched_recent: pd.DataFrame, alerts_now: pd.DataFrame | list[dict], model: dict, now: float | None = None,
                stop_name=None, hold_sec: float = 2 * 300) -> list[dict]:
    """Slowdowns holding right now (analysis/prewarn.py's episodes over the last hour of schedule-matched arrivals),
    each with where it is, since when, what the trains lost, whether a delay alert already covers the line, and the
    share of such slowdowns an alert naming a nearby station followed within 30 and 60 minutes, with its lift over
    chance. The pre-warning for a line with no alert: a slowdown notice first, with the alert clause in the text
    only where the record shows a real lift."""
    from ..analysis import prewarn as pw
    now = now or time.time()
    pwm = model.get("prewarn") or {}
    if matched_recent is None or matched_recent.empty or not pwm.get("all"):
        return []
    losses = pw.segment_losses(matched_recent)
    eps = pw.slowdown_episodes(losses)
    if eps.empty:
        return []
    eps = eps[eps["end_ts"] >= now - hold_sec]
    rows = alerts_now.to_dict(orient="records") if isinstance(alerts_now, pd.DataFrame) else list(alerts_now or [])
    alerted = set()
    for a in rows:
        if alert_kind(a.get("alert_type"), a.get("header") or "") == "delay" and "delay" in str(a.get("alert_type") or "").lower():
            alerted |= {str(r) for r in (a.get("routes") or [])}
    name = stop_name or (lambda s: s)
    out = []
    for e in eps.itertuples(index=False):
        route = str(e.route_id)
        p30, p60, lift, basis = pw.score_slowdown(pwm, route, float(e.peak_loss_sec), int(e.peak_n_slow), e.band)
        covered = route in alerted
        since = max(0.0, (now - e.onset_ts) / 60)
        where = f"{name(e.from_stop)} → {name(e.to_stop)}"
        way = {"N": "uptown", "S": "downtown"}.get(e.direction, "")
        text = (f"{route} {way}: {e.peak_n_slow} of {e.peak_n} trains lost {e.peak_loss_sec / 60:.1f} min between {where} over the last 20 min, "
                f"since {time.strftime('%-H:%M', time.localtime(e.onset_ts))}")
        if covered:
            text += " · a delay alert is already posted"
        else:
            text += " · no alert yet"
            if lift >= 1.5 and p30 >= 0.04:
                text += f" · an alert nearby follows {p30:.0%} of such slowdowns within 30 min, {lift:.0f}× the usual"
        out.append({"route": route, "direction": e.direction, "from_stop": e.from_stop, "to_stop": e.to_stop, "where": where,
                    "onset_ts": float(e.onset_ts), "since_min": round(since, 1), "loss_sec": round(float(e.peak_loss_sec)), "n_slow": int(e.peak_n_slow),
                    "n_trains": int(e.peak_n), "alerted": covered, "p_alert_30": round(p30, 3), "p_alert_60": round(p60, 3), "lift_30": round(lift, 2),
                    "basis": basis, "text": text})
    out.sort(key=lambda x: (x["alerted"], -x["loss_sec"] * x["n_slow"]))
    return out


def feed_from_routes(routes: list[dict]) -> dict:
    """`feed` for assess_alerts from the live snapshot's per-route summaries (realtime.status.route_status): both
    directions of a route pooled, the median lateness weighted by trains, held and stalled counted together."""
    per: dict[str, dict] = {}
    for r in routes or []:
        route = str(r.get("route_id") or "")
        n = int(r.get("trains") or 0)
        late = r.get("median_lateness_sec")
        pos = r.get("positions") or {}
        d = per.setdefault(route, {"late_w": 0.0, "w": 0, "n_trains": 0, "n_held": 0})
        if late is not None and n > 0:
            d["late_w"] += float(late) * n
            d["w"] += n
        d["n_trains"] += n
        d["n_held"] += int(pos.get("holding") or 0) + int(pos.get("stalled") or 0)
    return {r: {"lateness_sec": d["late_w"] / d["w"] if d["w"] else 0.0, "n_trains": d["n_trains"], "n_held": d["n_held"]} for r, d in per.items()}


def feed_from_boards(boards: dict) -> dict:
    """`feed` for assess_alerts from the live boards (realtime.status / build_live): per route, the median effective
    lateness of trains in service and the held or overdue count."""
    per: dict[str, dict] = {}
    for key, b in (boards or {}).items():
        route = str(b.get("route") or key.split("_")[0])
        trains = b.get("trains") or []
        lat = [float(t.get("effective_lateness_sec") or t.get("lateness_sec") or 0) for t in trains if t.get("started", True)]
        held = sum(1 for t in trains if (t.get("position") or {}).get("holding") or (t.get("position") or {}).get("stalled"))
        d = per.setdefault(route, {"lateness": [], "n_trains": 0, "n_held": 0})
        d["lateness"].extend(lat)
        d["n_trains"] += len(lat)
        d["n_held"] += held
    return {r: {"lateness_sec": float(np.median(d["lateness"])) if d["lateness"] else 0.0, "n_trains": d["n_trains"], "n_held": d["n_held"]}
            for r, d in per.items()}
