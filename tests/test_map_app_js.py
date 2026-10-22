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
