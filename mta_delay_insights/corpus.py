"""The training corpus: the stations the rider's train stopped at, as the phone felt them.

In ultra training mode (a TestFlight tester's own choice) the phone sends each route's motion trace (one summarised
second per line) with the trip. The stops are read from the trace by the train's own push (`felt_stops_from_trace`):
a sustained push is the train braking or pulling away, and the stretch of low push between a braking and the next
pull-away is the train standing. The shake does not tell: at a platform, doors and people keep it at the level of
cruising (Oct 12 on the F: 0.01-0.1 g standing, 0.02-0.04 g between stations), which is why the phone's own quiet
rule, kept as `stopSpans`, felt one of the F's four stations; those spans stand in only when a trip has no trace.
Each ride's stops are then named from the train the trip review matched to the leg: its recorded arrivals in the
store, put back to the platform moment by the line's lag, aligned in order with the felt stops (`align`). Lulls in a
run (low push while cruising) read as stops too; they match no station and are left over as `unmatched`; a station
with no felt stop went unfelt or the train ran through.

Each label is a true arrival at a named platform, the departure and the dwell, beside the feed's recorded time: what
PlatformTiming, the dwell model and the arrival model otherwise infer second-hand. The alignment needs a lag to line
the two up (the current table); the residuals measure how far the table is off, within the gate.

The corpus holds the rider's movements and lives in data/corpus (git-ignored: the repository is public).
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd

from . import trips as tr

# the stops in a trace
STEP_THRESHOLD = 0.012       # BoardingDetector: stepping, not riding
PUSH_ON = 0.05               # a push this strong is the train braking or pulling away ...
PUSH_RUN = 3                 # ... for this many seconds (gaps of a second or two inside it allowed)
QUIET_PUSH = 0.035           # the 3-second median push stays under this while the train stands
MIN_STAND_SEC = 8.0
MAX_STAND_SEC = 150.0
ALIGHT_STAND_SEC = 150.0     # the walk-off came this soon after the last braking: the train stood at that stop

# the alignment (Oct 12, F: the four stations' felt arrivals 6-24 s off the platform moment by the table)
SIGMA_SEC = 45.0             # a felt arrival against the station's platform moment
GATE_SEC = 100.0             # never matched further off than this (the C's dwell at Jay St came out 109 s off High St)
SKIP_FELT = 4.0              # a felt stop that is no station (a lull in the run, a signal)
SKIP_STATION = 2.0           # a station passed with no stop felt (unfelt, or run through)
UNIQUE_MARGIN = 1.0          # sure: the match leads the next-best station for this stop, and the next-best stop for
                             # this station, by this much (Oct 12, F: the four right matches led lulls by 0.8-2.9; one
                             # ride to set it by, so the corpus keeps the margin for a better cut later)


@dataclass
class Span:
    start: float
    end: float | None
    alighting: bool = False
    commotion: float | None = None    # the most stepping felt from 5 s before the stand to its end (doors, people)


def _rides(events: list[dict]) -> list[tuple[float, float | None]]:
    evs = sorted((e for e in events if isinstance(e, dict) and e.get("ts")), key=lambda e: e["ts"])
    rides: list[tuple[float, float | None]] = []
    for e in evs:
        if e.get("kind") == "departed":
            rides.append((float(e["ts"]), None))
        elif e.get("kind") == "alighted" and rides and rides[-1][1] is None:
            rides[-1] = (rides[-1][0], float(e["ts"]))
    return rides


def push_episodes(ts: np.ndarray, step: np.ndarray, push: np.ndarray) -> list[tuple[float, float]]:
    """Sustained pushes (braking, pulling away): PUSH_RUN seconds or more at PUSH_ON, not stepping, with gaps of up
    to two seconds inside."""
    moving = (push >= PUSH_ON) & (step <= STEP_THRESHOLD)
    eps: list[tuple[float, float]] = []
    i = 0
    while i < len(ts):
        if not moving[i]:
            i += 1
            continue
        n, last, j = 0, i, i
        while j < len(ts) and (moving[j] or ts[j] - ts[last] <= 2):
            if moving[j]:
                n, last = n + 1, j
            j += 1
        if n >= PUSH_RUN:
            eps.append((float(ts[i]), float(ts[last])))
        i = last + 1
    return eps


def stops_in(seconds: list, ix: dict, dep: float, ali: float | None) -> list[Span]:
    """The stands of one ride: between a push episode and the next, the stretch before the pull-away over which the
    3-second median push stays quiet (MIN_STAND_SEC to MAX_STAND_SEC); with the walk-off, the stand after the last
    braking, marked as the alighting."""
    rows = [r for r in seconds if r[ix["ts"]] >= dep - 2 and (ali is None or r[ix["ts"]] <= ali + 2)]
    if not rows:
        return []
    ts = np.array([float(r[ix["ts"]]) for r in rows])
    step = np.array([float(r[ix["stepEnergy"]]) for r in rows])
    push = np.array([float(r[ix["pushG"]]) for r in rows])
    eps = push_episodes(ts, step, push)
    out: list[Span] = []
    for (_, a1), (b0, _) in zip(eps, eps[1:]):
        if not MIN_STAND_SEC <= b0 - a1 <= MAX_STAND_SEC:
            continue
        sel = np.where((ts > a1) & (ts < b0))[0]
        if len(sel) == 0:
            continue
        med = [float(np.median(push[max(sel[0], k - 1):k + 2])) for k in sel]
        k = len(sel) - 1
        while k > 0 and med[k - 1] < QUIET_PUSH:
            k -= 1
        arrive = float(ts[sel[k]])
        if b0 - arrive >= MIN_STAND_SEC:
            near = (ts >= arrive - 5) & (ts <= b0)
            out.append(Span(arrive, b0, commotion=float(step[near].max()) if near.any() else None))
    if ali is not None:
        ends = [e1 for _, e1 in eps if e1 < ali]
        if ends and ali - max(ends) <= ALIGHT_STAND_SEC:
            after = ts[ts > max(ends)]                       # the first second standing after the braking
            out.append(Span(float(after[0]) if len(after) else max(ends), None, True))
    return out


def felt_stops_from_trace(trace: dict, events: list[dict]) -> dict[int, list[Span]]:
    """The station stops on each ride of a trace (the trip's own events, after its withdrawals), by the push."""
    cols = trace.get("columns") or ["ts", "stepEnergy", "pushG", "shakeG"]
    ix = {c: i for i, c in enumerate(cols)}
    secs = trace.get("seconds") or []
    return {k: stops_in(secs, ix, dep, ali) for k, (dep, ali) in enumerate(_rides(events))}


def felt_stops_from_trip(o: dict) -> dict[int, list[Span]]:
    """The station stops the phone itself kept (ultra training mode), per ride."""
    out: dict[int, list[Span]] = {}
    for s in o.get("stopSpans") or []:
        if not isinstance(s, dict) or s.get("start") is None:
            continue
        out.setdefault(int(s.get("ride", 0)), []).append(
            Span(float(s["start"]), float(s["end"]) if s.get("end") is not None else None, bool(s.get("alighting"))))
    for v in out.values():
        v.sort(key=lambda x: x.start)
    return out


@dataclass
class Station:
    stop_id: str
    name: str
    recorded_ts: float
    platform_ts: float          # recorded, put back by the line's lag


@dataclass
class Match:
    felt: int | None
    station: int | None
    cost: float
    margin: float | None = None


def _cost(f: float, s: Station) -> float | None:
    d = f - s.platform_ts
    return (d / SIGMA_SEC) ** 2 if abs(d) <= GATE_SEC else None


def align(felt: list[Span], stations: list[Station]) -> list[Match]:
    """The felt stops and the stations the train made, matched in order at least cost: a match costs the squared
    miss in sigmas, a felt stop left over SKIP_FELT, a station passed unfelt SKIP_STATION. The alighting stop, when
    both ends are known, must be the last station. Each match carries its margin: how much worse the same felt stop
    fits the next-best station in the gate (None: no other station in reach)."""
    n, m = len(felt), len(stations)
    INF = float("inf")
    D = np.full((n + 1, m + 1), INF)
    back: dict[tuple[int, int], tuple[int, int, str]] = {}
    D[0, 0] = 0.0
    for i in range(n + 1):
        for j in range(m + 1):
            if D[i, j] == INF:
                continue
            if i < n and D[i, j] + SKIP_FELT < D[i + 1, j]:
                D[i + 1, j] = D[i, j] + SKIP_FELT
                back[(i + 1, j)] = (i, j, "felt")
            if j < m and D[i, j] + SKIP_STATION < D[i, j + 1]:
                D[i, j + 1] = D[i, j] + SKIP_STATION
                back[(i, j + 1)] = (i, j, "station")
            if i < n and j < m:
                # the walk-off stop is the last station or nothing
                if felt[i].alighting and j != m - 1:
                    continue
                c = _cost(felt[i].start, stations[j])
                if c is not None and D[i, j] + c < D[i + 1, j + 1]:
                    D[i + 1, j + 1] = D[i, j] + c
                    back[(i + 1, j + 1)] = (i, j, "match")
    out: list[Match] = []
    i, j = n, m
    while (i, j) != (0, 0):
        pi, pj, how = back[(i, j)]
        if how == "match":
            out.append(Match(pi, pj, float(D[i, j] - D[pi, pj])))
        elif how == "felt":
            out.append(Match(pi, None, SKIP_FELT))
        else:
            out.append(Match(None, pj, SKIP_STATION))
        i, j = pi, pj
    out.reverse()
    for mt in out:
        if mt.felt is None or mt.station is None:
            continue
        # how much worse the next-best station fits this stop, and the next-best stop fits this station
        others = [c for k, s in enumerate(stations) if k != mt.station and (c := _cost(felt[mt.felt].start, s)) is not None]
        rivals = [c for k, f in enumerate(felt) if k != mt.felt and (c := _cost(f.start, stations[mt.station])) is not None]
        both = others + rivals
        mt.margin = (min(both) - mt.cost) if both else None
    return out


def _train_stations(con, trip_key: str, route: str, after_ts: float, until_ts: float) -> list[Station]:
    rows = con.execute("SELECT stop_id, arrival_ts FROM arrivals WHERE trip_key = ? ORDER BY arrival_ts", (trip_key,)).fetchall()
    out = []
    for sid, ats in rows:
        p = tr.at_platform(float(ats), route)
        # the boarding stop counts: the felt departure may be the train pulling in (the C at Jay St, Oct 12)
        if float(ats) >= after_ts - 1 and p <= until_ts:
            out.append(Station(str(sid), "", float(ats), p))
    return out


def label_trip(o: dict, review: dict, con, static, trace: dict | None) -> list[dict]:
    """The labelled station stops of one trip: per leg the review matched to a train, its felt stops against that
    train's stations from the boarding stop to the walk-off."""
    felt_by_ride, source = {}, "trace"
    if trace is not None:
        felt_by_ride = felt_stops_from_trace(trace, o.get("events") or [])
    if not any(felt_by_ride.values()):
        felt_by_ride, source = felt_stops_from_trip(o), "phone"
    if not felt_by_ride:
        return []
    rows = []
    for leg in review.get("legs") or []:
        train, ride = leg.get("train"), leg.get("ride")
        if not train or ride is None or not train.get("trip_key") or not leg.get("departedTs"):
            continue
        felt = felt_by_ride.get(int(ride)) or []
        route = str(train.get("route") or "")
        until = float(leg.get("alightedTs") or review.get("endedTs") or leg["departedTs"] + 3600) + 30
        stations = _train_stations(con, str(train["trip_key"]), route, float(train["arrivedBoardTs"]), until)
        if not felt or not stations:
            continue
        for st in stations:
            st.name = static.stop_name(st.stop_id) if static is not None else st.stop_id
        for mt in align(felt, stations):
            base = {"trip_id": o.get("id"), "install": (o.get("installId") or "")[:8], "build": o.get("appVersion"), "source": source,
                    "day": review.get("day"), "leg": leg.get("leg"), "route": route, "train_trip": train.get("trip_id"),
                    "direction": (leg.get("plan") or "_").split("_")[-1]}
            if mt.felt is not None and mt.station is not None:
                f, s = felt[mt.felt], stations[mt.station]
                rows.append(base | {"kind": "station", "stop_id": s.stop_id, "stop_name": s.name, "felt_arrive_ts": f.start,
                                    "felt_depart_ts": None if f.alighting else f.end, "dwell_sec": (f.end - f.start) if f.end and not f.alighting else None,
                                    "alighting": f.alighting, "recorded_ts": s.recorded_ts, "lag_sec": s.recorded_ts - f.start,
                                    "residual_sec": f.start - s.platform_ts, "margin": mt.margin, "commotion": f.commotion,
                                    "boarding": mt.station == 0,
                                    "sure": mt.margin is None or mt.margin >= UNIQUE_MARGIN})
            elif mt.felt is not None:
                f = felt[mt.felt]
                rows.append(base | {"kind": "unmatched", "felt_arrive_ts": f.start, "felt_depart_ts": f.end,
                                    "dwell_sec": (f.end - f.start) if f.end else None, "alighting": f.alighting})
            elif mt.station > 0:      # the boarding stop unfelt: the rider got on while it stood, nothing to time
                s = stations[mt.station]
                rows.append(base | {"kind": "unfelt", "stop_id": s.stop_id, "stop_name": s.name, "recorded_ts": s.recorded_ts})
    return rows


def build(out_dir: Path, con, static, trips_dir: Path = Path("data/trips")) -> pd.DataFrame:
    """Every trip with felt stops (its own, or a trace's) and a train the review matched, labelled."""
    review = json.loads((trips_dir / "trip_review.json").read_text())
    reviews = {r["id"]: r for r in review.get("trips") or review.get("reviews") or []}
    obs = {o["id"]: o for o in tr.load_ledger(trips_dir / "observations.jsonl")}
    traces = tr.load_traces(trips_dir)
    rows = []
    for tid, o in obs.items():
        r = reviews.get(tid)
        if r is None:
            continue
        trace = traces.get(int(float(o.get("createdTs") or 0)))
        rows += label_trip(o, r, con, static, trace)
    df = pd.DataFrame(rows)
    out_dir.mkdir(parents=True, exist_ok=True)
    df.to_csv(out_dir / "station_stops.csv", index=False)
    return df


def summarize(df: pd.DataFrame) -> dict:
    """Per line: the labelled stops, the feed's lag behind the platform (vs the table), the dwell, how many stations
    the phone felt, and the felt stops that matched no station."""
    if df.empty:
        return {"n": 0, "lines": {}}
    out: dict = {"n_trips": int(df["trip_id"].nunique()), "n_station_stops": int((df["kind"] == "station").sum()), "lines": {}}
    for route, g in df.groupby("route"):
        st = g[g["kind"] == "station"]
        sure = st[st["sure"] == True]  # noqa: E712
        dw = sure["dwell_sec"].dropna()
        passed = int((g["kind"] != "unmatched").sum())
        out["lines"][str(route)] = {
            "n_labelled": int(len(st)), "n_sure": int(len(sure)),
            "lag_sec_p50": float(sure["lag_sec"].median()) if len(sure) else None,
            "lag_sec_iqr": [float(sure["lag_sec"].quantile(.25)), float(sure["lag_sec"].quantile(.75))] if len(sure) >= 4 else None,
            "lag_table_sec": float(tr.RECORDED_LAG.get(str(route), tr.DEFAULT_LAG)),
            "dwell_sec_p50": float(dw.median()) if len(dw) else None, "n_dwell": int(len(dw)),
            "felt_share": float(len(st) / passed) if passed else None,
            "n_unmatched": int((g["kind"] == "unmatched").sum()),
        }
    return out


def render(s: dict) -> str:
    lines = ["# Station-stop corpus", "",
             f"{s.get('n_trips', 0)} trips, {s.get('n_station_stops', 0)} station stops named. Lag: the feed's recorded time minus the "
             "felt arrival (what PlatformTiming holds per line). Sure: the felt stop fits its station by a clear margin over the next.", "",
             "| Line | Named | Sure | Lag p50 (IQR) | Table | Dwell p50 (n) | Stations felt | Unmatched stops |",
             "|---|---|---|---|---|---|---|---|"]
    for r, d in sorted((s.get("lines") or {}).items()):
        lag = "–" if d["lag_sec_p50"] is None else f"{d['lag_sec_p50']:.0f} s" + (f" ({d['lag_sec_iqr'][0]:.0f}–{d['lag_sec_iqr'][1]:.0f})" if d["lag_sec_iqr"] else "")
        dw = "–" if d["dwell_sec_p50"] is None else f"{d['dwell_sec_p50']:.0f} s ({d['n_dwell']})"
        fs = "–" if d["felt_share"] is None else f"{d['felt_share']:.0%}"
        lines.append(f"| {r} | {d['n_labelled']} | {d['n_sure']} | {lag} | {d['lag_table_sec']:.0f} s | {dw} | {fs} | {d['n_unmatched']} |")
    return "\n".join(lines) + "\n"
