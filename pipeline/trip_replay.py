"""Replay the stored trips through the phone's own decisions (CLAUDE.md, transfers rule 4).

    python -m pipeline.trip_replay --db data/mta.sqlite --trips data/trips      # export, then run the Swift replay
    python -m pipeline.trip_replay --export-only                                # just write the fixtures

For each trip that has a motion trace, a fixture goes to data/trips/replay/<start>.json (git-ignored: it holds the
rider's movements): the trip's record as the phone kept it, its trace (one summarised second per row), the trains
the store recorded around it (every train of every line calling at a station on the route's legs, from half an hour
before the route to half an hour after it ended: their times at each stop, and when the feed had them standing at
one), and what the trip review knows of it (the rider's own lines, the trains matched to each leg).

The Swift side (`TripReplayTests`, run only when WHICHWAY_REPLAY points at the fixtures) builds the feed's boards poll
by poll from those trains (each train lists the stops still ahead of it, at the time the store recorded there),
feeds the trace second by second into `RideSession` with the boards every 30 s, and writes what the phone would decide
on current code: the legs ridden, the line and train called per leg, each hand-off and when. Its report lands beside
the fixtures (replay_report.md / .json) to compare against the trip as it happened and the rider's own account.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import subprocess
import sys
from pathlib import Path

from mta_delay_insights import trips as tr
from mta_delay_insights.storage.db import Store
from pipeline import lib

log = logging.getLogger("trip_replay")
MARGIN_SEC = 1800.0
TRIP_FIELDS = ["id", "createdTs", "startTs", "endedTs", "endedBy", "startedBy", "startDistanceM", "routeLabel", "transferStation",
               "transferWalkSec", "legs", "events", "withdrawnDepartures", "notOnTrainTaps", "changedEarlyTaps", "boarded",
               "beliefLog", "rideStops", "stopSpans", "appBuild", "predictedBoardTs", "predictedArriveTs", "rideAssumed", "devNotes",
               "startRouteLabel", "startLegs", "routeChanges"]


def route_stations(schedule: dict, legs: list[dict]) -> set[str]:
    """Every stop id of every line that calls at a station of the trip's legs (from the boarding stop to the alighting
    stop on the leg's own line), by parent station."""
    lines = schedule.get("lines") or {}
    parents: set[str] = set()
    for lg in legs:
        stops = (lines.get(lg.get("line") or "") or {}).get("stops") or []
        a, b = lg.get("from"), lg.get("to")
        if a in stops and b in stops and stops.index(a) <= stops.index(b):
            parents.update(s[:-1] for s in stops[stops.index(a):stops.index(b) + 1])
        else:
            parents.update(s[:-1] for s in (a, b) if s)
    return parents


def routes_at(schedule: dict, parents: set[str]) -> set[str]:
    out: set[str] = set()
    for key, line in (schedule.get("lines") or {}).items():
        if any(s[:-1] in parents for s in line.get("stops") or []):
            out.add(key.split("_")[0])
    return out


def trains_around(store: Store, routes: set[str], t0: float, t1: float) -> tuple[list[list], list[list]]:
    """The store's arrivals and dwells for `routes` between t0 and t1: [trip_id, route, direction, stop, arrival, departure]
    and [trip_id, stop, stopped_from, stopped_to]."""
    if not routes:
        return [], []
    marks = ",".join("?" * len(routes))
    arr = store.conn.execute(
        f"SELECT trip_key, trip_id, route_id, direction, stop_id, arrival_ts, departure_ts FROM arrivals "
        f"WHERE route_id IN ({marks}) AND arrival_ts BETWEEN ? AND ? ORDER BY arrival_ts", [*sorted(routes), t0, t1]).fetchall()
    keys = sorted({r[0] for r in arr})
    dw: list[list] = []
    for i in range(0, len(keys), 500):
        chunk = keys[i:i + 500]
        dw += store.conn.execute(f"SELECT trip_key, stop_id, stopped_from_ts, stopped_to_ts FROM dwells WHERE trip_key IN ({','.join('?' * len(chunk))})",
                                 chunk).fetchall()
    ids = {r[0]: r[1] for r in arr}
    return ([[r[1], r[2], r[3], r[4], r[5], r[6]] for r in arr],
            [[ids.get(r[0], r[0]), r[1], r[2], r[3]] for r in dw])


def truth_for(review: dict | None) -> dict:
    if not review:
        return {}
    return {"riderLines": review.get("riderLines") or [],
            "legs": [{"leg": lg.get("leg"), "riderRoute": lg.get("riderRoute"), "riderTransfer": lg.get("riderTransfer"),
                      "train": (lg.get("train") or {}).get("trip_id"), "route": (lg.get("train") or {}).get("route"),
                      "matchedBy": lg.get("matchedBy"), "plan": lg.get("plan")} for lg in review.get("legs") or []],
            "missedChange": review.get("missedChange"), "falseStart": review.get("falseStart")}


def export(store: Store | None, trips_dir: Path, schedule: dict, out_dir: Path) -> list[Path]:
    obs = tr.collect_observations(None, trips_dir) if store is None else tr.collect_observations(store, trips_dir)
    traces = {**tr.load_traces(trips_dir / "device"), **tr.load_traces(trips_dir / "github")}
    reviews = {}
    rj = trips_dir / tr.REPORT_JSON
    if rj.exists():
        reviews = {r["id"]: r for r in json.loads(rj.read_text()).get("trips") or []}
    out_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for o in obs:
        start = float(o.get("createdTs") or 0)
        trace = next((traces[k] for k in traces if abs(k - start) <= 5), None)
        if trace is None or not o.get("legs"):
            continue
        t0, t1 = start - MARGIN_SEC, float(o.get("endedTs") or start + 7200) + MARGIN_SEC
        routes = routes_at(schedule, route_stations(schedule, o["legs"] + (o.get("startLegs") or [])))
        arr, dw = trains_around(store, routes, t0, t1) if store is not None else ([], [])
        fx = {"trip": {k: o.get(k) for k in TRIP_FIELDS if k in o},
              "trace": {"columns": trace.get("columns"), "seconds": trace.get("seconds"), "startTs": trace.get("startTs")},
              "arrivals": arr, "dwells": dw, "truth": truth_for(reviews.get(o["id"]))}
        p = out_dir / f"{int(start)}.json"
        p.write_text(json.dumps(fx, separators=(",", ":")))
        written.append(p)
    return written


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", default=str(lib.ROOT / "data" / "mta.sqlite"))
    ap.add_argument("--trips", default=str(lib.ROOT / "data" / "trips"))
    ap.add_argument("--schedule", default=None, help="client_schedule.json (default: site/data, else the published one on gh-pages)")
    ap.add_argument("--out", default=None, help="fixtures folder (default: <trips>/replay)")
    ap.add_argument("--export-only", action="store_true")
    a = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    trips_dir = Path(a.trips)
    out_dir = Path(a.out) if a.out else trips_dir / "replay"
    sched_path = Path(a.schedule) if a.schedule else lib.ROOT / "site" / "data" / "client_schedule.json"
    if sched_path.exists():
        schedule = json.loads(sched_path.read_text())
    else:
        raw = subprocess.run(["git", "show", "origin/gh-pages:data/client_schedule.json"], cwd=lib.ROOT, capture_output=True, text=True)
        if raw.returncode != 0:
            log.error("no client_schedule.json: pass --schedule")
            return 1
        schedule = json.loads(raw.stdout)
        sched_path = out_dir / "client_schedule.json"
        out_dir.mkdir(parents=True, exist_ok=True)
        sched_path.write_text(raw.stdout)
    store = Store(a.db) if Path(a.db).exists() else None
    written = export(store, trips_dir, schedule, out_dir)
    log.info("%d trip fixture(s) → %s", len(written), out_dir)
    if a.export_only:
        return 0
    env = {**os.environ, "WHICHWAY_REPLAY": str(out_dir.resolve()), "WHICHWAY_SCHEDULE": str(sched_path.resolve())}
    r = subprocess.run(["swift", "test", "--filter", "TripReplayTests"], cwd=lib.ROOT / "ios" / "WhichWayCore", env=env)
    report = out_dir / "replay_report.md"
    if report.exists():
        print(report.read_text())
    return r.returncode


if __name__ == "__main__":
    sys.exit(main())
