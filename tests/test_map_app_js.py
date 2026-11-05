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


REPORTS_HARNESS = """
import { normStop, liveReports, groupReports, matchDetections, groupTitle, demoReports } from "%(reports)s";
const now = 100000;
const lines = { A_S: { key: "A_S", dir: "S", mode: "live", line: { stops: ["A40S", "A41S", "A42S", "A43S", "A44S"], names: ["a", "b", "c", "d", "e"] } } };
const reports = [
  { id: "1", ts: now - 60, kind: "held", route: "A", dir: "S", stop: "A41S", rider: "r1" },
  { id: "2", ts: now - 30, kind: "held", route: "A", dir: "S", stop: "A41", rider: "r2" },
  { id: "3", ts: now - 20, kind: "held", route: "A", dir: "S", stop: "A41", rider: "r2" },      // the same rider again
  { id: "4", ts: now - 3000, kind: "held", route: "A", dir: "S", stop: "A41", rider: "r3" },    // past its 20 min
  { id: "5", ts: now - 100, kind: "all_good", route: "A", stop: "A44", rider: "r4" },             // no direction: either
  { id: "6", ts: now - 100, kind: "crowded", sub: "packed", route: "A", dir: "S", stop: "A40", rider: "r5" },
];
const events = [
  { key: "hold|A_S|t1", kind: "hold", lineKey: "A_S", stopIdx: 2, open: true, first_ts: now - 200, title: "A train held at c" },
  { key: "gap|A_S|t9", kind: "gap", lineKey: "A_S", stopIdx: 4, open: true, first_ts: now - 400, title: "20 min gap in A service" },
];
const live = liveReports(reports, now);
const groups = groupReports(live);
const m = matchDetections(groups, events, lines);
console.log(JSON.stringify({ norm: [normStop("A41S"), normStop("631"), normStop("R14N")], live: live.map(r => r.id), groups,
  byEvent: Object.fromEntries(m.byEvent), byGroup: Object.fromEntries([...m.byGroup].map(([k, v]) => [k, { ev: v.event && v.event.key, verdict: v.verdict }])),
  titles: groups.map(groupTitle), demo: demoReports(events, lines, now).length }));
"""


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
def test_rider_reports_group_and_match_detections(tmp_path):
    h = tmp_path / "r.mjs"
    h.write_text(REPORTS_HARNESS % {"reports": (ROOT / "site/map/reports.js").as_uri()})
    out = json.loads(subprocess.run(["node", str(h)], capture_output=True, text=True, check=True).stdout)
    assert out["norm"] == ["A41", "631", "R14"]
    assert "4" not in out["live"]                                           # a held report lasts 20 minutes
    held = next(g for g in out["groups"] if g["kind"] == "held")
    assert held["count"] == 2 and held["stop"] == "A41"                     # two riders, one of them twice
    assert out["byGroup"][held["id"]] == {"ev": "hold|A_S|t1", "verdict": "confirms"}   # one stop from the detected hold
    good = next(g for g in out["groups"] if g["kind"] == "all_good")
    assert out["byGroup"][good["id"]] == {"ev": "gap|A_S|t9", "verdict": "disputes"}
    assert out["byEvent"]["hold|A_S|t1"] == {"confirm": 2, "dispute": 0}
    crowd = next(g for g in out["groups"] if g["kind"] == "crowded")
    assert out["byGroup"][crowd["id"]]["verdict"] is None                   # crowding confirms no detection
    assert "Crowded (packed) · 1 rider" in out["titles"]
    assert out["demo"] >= 1


@pytest.mark.skipif(shutil.which("node") is None, reason="node not installed")
def test_service_gaps_follow_the_timetable_at_the_stop(tmp_path):
    h = tmp_path / "g.mjs"
    h.write_text(GAPS_HARNESS % {"engine": (ROOT / "site/map/engine.js").as_uri()})
    out = json.loads(subprocess.run(["node", str(h)], capture_output=True, text=True, check=True).stdout)
    assert out["peak"] == [{"ahead": "x", "behind": "y", "stop": 3, "wait": 1500, "hw": pytest.approx(480, rel=0.15), "missing": 3, "severity": "medium"}]
    assert out["midday"] == 0
    assert out["atOrigin"] == 0
    assert out["sg"]["longest"] == 600 and out["sg"]["hw"] == pytest.approx(600, rel=0.1)
