"""The map app's geometry and schedule-position fallback (site/map/geo.js, site/map/engine.js)."""
from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
HARNESS = """
import { buildLine } from "%(geo)s";
import { scheduledTrains, cumRun, routeHealth } from "%(engine)s";
// an L-shaped line: three stops north along a street, then two east; the shape bends at the corner
const geo = { coords: [[40.70, -74.00], [40.71, -74.00], [40.72, -74.00], [40.72, -73.99], [40.72, -73.98]],
  shape: [[40.72, -73.98], [40.72, -73.99], [40.72, -74.00], [40.715, -74.00], [40.70, -74.00]] };   // exported the other way round
const L = buildLine(geo);
const line = { stops: ["A", "B", "C", "D", "E"], names: ["a", "b", "c", "d", "e"], run_sec: [60, 60, 120, 120] };
const cum = cumRun(line);
const now = 10000;
// one trip reaching the last stop 180 s from now: 180 s of running left puts it a quarter of the way from c to d... (c->d is 120 s, d->e 120 s)
const trains = scheduledTrains(line, [["t1", 4, now + 180], ["t2", 4, now - 10], ["t3", 4, now + 9999]], cum, now);
const health = routeHealth({ lines: { X_N: { key: "X_N", route: "X", mode: "live" } }, trains: [{ route: "X", dir: "N", late: 400, position: { holding: true, stalled: false } }, { route: "X", dir: "N", late: 30, position: null }], events: [], alerts: [] });
console.log(JSON.stringify({ n: L.n, at0: L.at(0), at2: L.at(2), at15: L.at(1.5), at25: L.at(2.5), between: L.between(1, 3), trains, health: health.get("X") }));
"""


@pytest.mark.skipif(shutil.which("node") is None, reason="node not installed")
def test_geometry_and_scheduled_positions(tmp_path):
    h = tmp_path / "h.mjs"
    h.write_text(HARNESS % {"geo": (ROOT / "site/map/geo.js").as_uri(), "engine": (ROOT / "site/map/engine.js").as_uri()})
    out = json.loads(subprocess.run(["node", str(h)], capture_output=True, text=True, check=True).stdout)
    assert out["n"] == 5
    assert out["at0"] == pytest.approx([-74.00, 40.70])
    assert out["at2"] == pytest.approx([-74.00, 40.72], abs=1e-6)          # the corner stop sits on the shape
    assert out["at15"] == pytest.approx([-74.00, 40.715], abs=1e-4)        # halfway between b and c, on the street
    assert out["at25"] == pytest.approx([-73.995, 40.72], abs=1e-4)        # halfway between c and d, along the cross street
    b = out["between"]
    assert b[0] == pytest.approx([-74.00, 40.71], abs=1e-6) and b[-1] == pytest.approx([-73.99, 40.72], abs=1e-6)
    assert [-74.00, 40.72] in [[round(x, 6) for x in p] for p in b]          # the track bends through the corner
    trains = {t["trip_id"]: t for t in out["trains"]}
    assert set(trains) == {"t1"}                                            # finished and not-yet-started trips are not drawn
    assert trains["t1"]["idx"] == pytest.approx(2.5)                        # 180 s left: halfway from c to d
    assert [p[0] for p in trains["t1"]["points"]] == [3, 4]
    assert trains["t1"]["points"][-1][1] == 10180
    hx = out["health"]
    assert hx["trains"] == 2 and hx["holding"] == 1 and hx["status"] in ("degraded", "disrupted")


GAPS_HARNESS = """
import { cumRun, serviceGaps, schedGapAt } from "%(engine)s";
const line = { stops: ["A", "B", "C", "D", "E", "F"], names: ["a", "b", "c", "d", "e", "f"], run_sec: [120, 120, 120, 120, 120] };
const cum = cumRun(line), now = 100000;
// trips reaching the last stop every `hw` seconds around now: [stem, last idx, ts at the last stop]
const timetable = hw => Array.from({ length: 40 }, (_, k) => [`t${k}`, 5, now - 10 * hw + k * hw]);
const tr = (id, pts) => ({ trip_id: id, points: pts.map(([i, dt]) => [i, now + dt]) });
// x is 8 min behind w at d: on schedule. y is 25 min behind x at d: two trains of the 8-min timetable are missing
const trains = [tr("w", [[4, 60], [5, 180]]), tr("x", [[3, 100], [4, 540], [5, 660]]), tr("y", [[2, 0], [3, 1600], [4, 2040]])];
const peak = serviceGaps(line, timetable(480), cum, trains);
// the same trains against a 20-min midday timetable: a 25-min wait is not a gap
const midday = serviceGaps(line, timetable(1200), cum, trains);
// a train that has not left the terminal area is not compared
const atOrigin = serviceGaps(line, timetable(480), cum, [trains[0], tr("z", [[1, 0], [4, 3000]])]);
console.log(JSON.stringify({ peak: peak.map(g => ({ ahead: g.ahead.trip_id, behind: g.behind.trip_id, stop: g.stop_idx, wait: g.wait, hw: g.hw, missing: g.missing, severity: g.severity })),
  midday: midday.length, atOrigin: atOrigin.length, sg: schedGapAt(cum, timetable(600), 3, now, now + 1200) }));
"""


@pytest.mark.skipif(shutil.which("node") is None, reason="node not installed")
def test_service_gaps_follow_the_timetable_at_the_stop(tmp_path):
    h = tmp_path / "g.mjs"
    h.write_text(GAPS_HARNESS % {"engine": (ROOT / "site/map/engine.js").as_uri()})
    out = json.loads(subprocess.run(["node", str(h)], capture_output=True, text=True, check=True).stdout)
    assert out["peak"] == [{"ahead": "x", "behind": "y", "stop": 3, "wait": 1500, "hw": pytest.approx(480, rel=0.15), "missing": 3, "severity": "medium"}]
    assert out["midday"] == 0
    assert out["atOrigin"] == 0
    assert out["sg"]["longest"] == 600 and out["sg"]["hw"] == pytest.approx(600, rel=0.1)
