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
