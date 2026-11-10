"""The client prediction engine: fitted tables and the reference predictor the browser and the phone port."""
from __future__ import annotations

import json
import math

import numpy as np
import pandas as pd
import pytest

from mta_delay_insights.realtime import client_model as cm
from tests.test_positions import _snapshot


def _arrivals(static):
    sim, now, feeds, _ = _snapshot(static)
    a = sim.arrivals.copy()
    return a, now


def test_eta_calibration_recovers_the_feed_bias(static):
    a, _ = _arrivals(static)
    rng = np.random.default_rng(1)
    rows = []
    for _, r in a.head(600).iterrows():
        for h in rng.choice([60, 200, 400, 900, 1500, 3000], size=2):
            # the feed promised the train 40 s before it actually came, h seconds ahead
            rows.append({"trip_key": r["trip_key"], "route_id": r["route_id"], "stop_id": r["stop_id"], "at_stop": "x",
                         "at_ts": r["arrival_ts"] - 40 - h, "stops_ahead": 3, "eta_ts": r["arrival_ts"] - 40})
    es = pd.DataFrame(rows)
    cal = cm.fit_eta_calibration(es, a)
    assert cal["n"] == len(rows)
    for b in cal["all"]:
        assert b["n"] > 0 and 30 <= b["bias"] <= 40 and b["p10"] < b["bias"] < b["p90"]
    assert cal["by_route"], "routes with enough samples get their own table"
    route = next(iter(cal["by_route"]))
    assert len(cal["by_route"][route]) == len(cm.HORIZON_EDGES) - 1
    # lookups: a known route uses its own table, an unknown route the all-routes table, out-of-range horizons clamp
    assert cm.calibration_at({"eta_calibration": cal}, route, 250) == cal["by_route"][route][1]
    assert cm.calibration_at({"eta_calibration": cal}, "Z", 250) == cal["all"][1]
    assert cm.calibration_at({"eta_calibration": cal}, route, 99999) == cal["by_route"][route][-1]
    empty = cm.fit_eta_calibration(None, None)
    assert empty["n"] == 0 and empty["all"][0]["bias"] == 0.0 and empty["all"][-1]["p90"] > empty["all"][0]["p90"]


def test_hold_survival_is_conditional_on_time_already_held(static):
    dw = pd.DataFrame({"trip_key": [f"t{i}" for i in range(400)], "route_id": "6", "direction": "N", "stop_id": "633N",
                       "stopped_from_ts": 1.0, "stopped_to_ts": 2.0, "dwell_sec": np.r_[np.full(200, 200.0), np.full(150, 400.0), np.full(50, 1500.0)], "polls": 3})
    sv = cm.fit_hold_survival(dw, static)
    assert sv["n_holds"] == 400 and sv["elapsed"] == cm.ELAPSED_GRID
    # held 150 s: most holds end soon; held 600 s: only the long ones remain, so the expected remainder is larger
    assert sv["expected"][0] < sv["expected"][3]
    assert sv["clears_2min"][0] > sv["clears_2min"][3]
    # no hold in the log lasted 1800 s: that grid point is the prior
    assert sv["n"][-1] == 0 and sv["expected"][-1] == cm.PRIOR_HOLD["expected"]
    # a few multi-hour holds must not dominate the expectation for trains held long (winsorized), while the
    # 90th percentile still reflects them
    tail = pd.concat([dw, dw.head(12).assign(trip_key=lambda x: "x" + x["trip_key"], dwell_sec=6000.0)])
    sv2 = cm.fit_hold_survival(tail, static)
    assert sv2["expected"][3] < 0.5 * (cm.WINSOR_REMAINING_SEC + (1500 - 600)) and sv2["p90"][3] >= 1400 - 600
    r150, r700 = cm.remaining_hold(sv, 150), cm.remaining_hold(sv, 700)
    assert r150["expected"] < r700["expected"] and r700["p90"] >= r700["p50"] >= 0
    # interpolation stays between the grid values; no log falls back to the prior
    r300 = cm.remaining_hold(sv, 300)
    assert min(sv["expected"][0], sv["expected"][1]) <= r300["expected"] <= max(sv["expected"][0], sv["expected"][1])
    prior = cm.fit_hold_survival(None)
    assert prior["n_holds"] == 0 and prior["expected"][0] == cm.PRIOR_HOLD["expected"]
    # terminal waits are not holds
    term = dw.assign(stop_id=static.canonical_stop_sequence("6", "N")[0])
    assert cm.fit_hold_survival(term, static)["n_holds"] == 0


def test_lateness_carry_fits_per_route_and_shrinks(static):
    a, _ = _arrivals(static)
    lc = cm.fit_lateness_carry(a, static, max_rows=5000)
    assert lc["max_k"] == cm.MAX_K and lc["n"] > 0
    assert len(lc["all"]["slope"]) == cm.MAX_K and all(0 <= s <= 1.5 for s in lc["all"]["slope"])
    assert all(r >= 15 for r in lc["all"]["resid_std"])
    c1 = cm.carry_at({"lateness_carry": lc}, "6", 1)
    assert c1 is not None and c1["resid_std"] >= 15
    assert cm.carry_at({"lateness_carry": lc}, "6", 0) is None and cm.carry_at({"lateness_carry": lc}, "6", 99) is None
    # no history: pure prior (carry-through)
    empty = cm.fit_lateness_carry(None, static)
    assert empty["all"]["slope"] == [1.0] * cm.MAX_K and empty["by_route"] == {}
    assert json.loads(json.dumps(cm.fit_client_model(None, None, None, static, "2026-01-01")))["version"] == cm.VERSION


def _line():
    return {"stops": [f"S{i}" for i in range(8)], "run_sec": [90, 120, 100, 110, 95, 130, 105]}


def _model(bias=0.0, spread=60.0, slope=1.0, intercept=0.0, resid=40.0):
    buckets = [{"n": 50, "bias": bias, "p10": bias - spread, "p90": bias + spread} for _ in range(len(cm.HORIZON_EDGES) - 1)]
    carry = {"slope": [slope] * cm.MAX_K, "intercept": [intercept] * cm.MAX_K, "resid_std": [resid] * cm.MAX_K, "n": [100] * cm.MAX_K}
    return {"eta_calibration": {"horizons": cm.HORIZON_EDGES, "all": buckets, "by_route": {}},
            "hold_survival": {"elapsed": cm.ELAPSED_GRID, "expected": [120, 150, 200, 260, 300, 400], "p50": [60, 90, 120, 180, 240, 300],
                              "p90": [400, 500, 600, 800, 900, 1200], "clears_2min": [0.5] * 6},
            "lateness_carry": {"max_k": cm.MAX_K, "all": carry, "by_route": {}}}


def _train(tid, next_idx, now, lateness=0.0, eff=None, pos=None, sched=None, step=120.0):
    pts = [[i, now + 60 + (i - next_idx) * step] for i in range(next_idx, 8)]
    return {"trip_id": tid, "route": "6", "next_idx": next_idx, "points": pts, "lateness_sec": lateness,
            "effective_lateness_sec": eff if eff is not None else lateness, "sched_ts": sched, "position": pos}


def test_predictor_calibrates_the_feed_and_keeps_stops_in_order():
    now = 1_000_000.0
    line = _line()
    t = _train("a", 2, now)
    p = cm.predict_train(t, line, _model(bias=25.0), now)
    assert [pt["idx"] for pt in p["points"]] == [2, 3, 4, 5, 6, 7]
    for pt in p["points"]:
        assert pt["source"] == "feed" and pt["eta_ts"] == pytest.approx(pt["feed_ts"] + 25.0)
        assert pt["lo_ts"] < pt["eta_ts"] < pt["hi_ts"]
    # a feed that jumps backwards is made monotone with a minimum stop gap, and never before now
    t2 = _train("b", 0, now)
    t2["points"][3][1] = now - 500
    p2 = cm.predict_train(t2, line, _model(), now)
    etas = [pt["eta_ts"] for pt in p2["points"]]
    assert all(b >= a + cm.MIN_STOP_GAP_SEC for a, b in zip(etas, etas[1:])) and min(etas) >= now


def test_predictor_blends_the_state_estimate_and_corrects_an_optimistic_feed():
    now = 1_000_000.0
    line = _line()
    sched_next = now + 60          # the feed says on time at the next stop
    # the schedule says the later stops come at sched_next + runs; the feed agrees; the train is 300 s late by position
    t = _train("a", 2, now, lateness=0.0, eff=300.0, sched=sched_next, step=100.0)
    feed_only = cm.predict_train(t, line, {"eta_calibration": _model()["eta_calibration"]}, now)
    blended = cm.predict_train(t, line, _model(spread=60.0, resid=40.0), now)
    # the position proves the feed 300 s optimistic: every point shifts by that much even without a carry table
    assert feed_only["points"][0]["eta_ts"] == pytest.approx(t["points"][0][1] + 300.0)
    # with a carry table the downstream stops lean toward schedule + carried lateness (sched + 300) where the state is more precise
    d = blended["points"][2]
    sched_d = sched_next + line["run_sec"][2] + line["run_sec"][3]
    assert d["source"] == "blend" and abs(d["eta_ts"] - (sched_d + 300.0)) < abs(d["eta_ts"] - d["feed_ts"]) + 1
    assert d["hi_ts"] - d["lo_ts"] < feed_only["points"][2]["hi_ts"] - feed_only["points"][2]["lo_ts"]
    # the next stop itself stays a feed estimate (k = 0)
    assert blended["points"][0]["source"] == "feed"


def test_predictor_hold_scenarios_and_cascade():
    now = 1_000_000.0
    line = _line()
    held = _train("held", 3, now, pos={"status": "STOPPED_AT", "since_sec": 400, "holding": True, "stalled": False})
    follower = _train("follower", 1, now)
    model = _model()
    base = cm.predict_line([held, follower], line, model, now, "baseline")
    persists = cm.predict_line([held, follower], line, model, now, "hold_persists")
    clears = cm.predict_line([held, follower], line, model, now, "clears_now")
    by = {sc: {p["trip_id"]: p for p in out["trains"]} for sc, out in (("b", base), ("p", persists), ("c", clears))}
    rem = cm.remaining_hold(model["hold_survival"], 400)
    assert by["b"]["held"]["hold_extra_sec"] == pytest.approx(rem["expected"]) and by["p"]["held"]["hold_extra_sec"] == pytest.approx(rem["p90"])
    assert by["c"]["held"]["hold_extra_sec"] == 0.0 and by["b"]["follower"]["hold_extra_sec"] == 0.0
    e = lambda p, i: next(pt["eta_ts"] for pt in p["points"] if pt["idx"] == i)
    assert e(by["c"]["held"], 5) < e(by["b"]["held"], 5) < e(by["p"]["held"], 5)
    # the follower cannot pass the held train: under hold_persists it is knocked on where they would overlap
    assert by["p"]["follower"]["knock_on_sec"] > 0 and e(by["p"]["follower"], 5) >= e(by["p"]["held"], 5) + cm.MIN_HEADWAY_SEC - 1e-6
    assert persists["n_knock_on"] >= 1 and persists["knock_on_total_sec"] > base["knock_on_total_sec"]
    assert persists["worst_gap"] and persists["worst_gap"]["gap_sec"] >= base["worst_gap"]["gap_sec"] - 1e-6
    assert all(s["n_arrivals"] >= 0 for s in base["per_stop"]) and len(base["per_stop"]) == len(line["stops"])
    json.dumps(persists)


PREDICT_HARNESS = """
import { predictLine, remainingHold, calibrationAt, isTimetableTrip } from "%s";
import { readFileSync } from "node:fs";
const inp = JSON.parse(readFileSync(process.argv[2], "utf8"));
const out = {};
for (const sc of inp.scenarios) out[sc] = predictLine(inp.trains, inp.line, inp.model, inp.now, sc);
out.rem = inp.elapsed.map(e => remainingHold(inp.model.hold_survival, e));
out.cal = inp.horizons.map(h => calibrationAt(inp.model, "6", h));
out.ttcal = inp.horizons.map(h => calibrationAt(inp.model, "6", h, true));
out.grid = [isTimetableTrip([1020, 1140, 1290, 1380]), isTimetableTrip([1020, 1141, 1290]), isTimetableTrip([1020, 1140]), isTimetableTrip([1020])];
console.log(JSON.stringify(out));
"""


def test_js_predictor_matches_python(static, tmp_path):
    import shutil
    import subprocess
    from pathlib import Path
    if shutil.which("node") is None:
        pytest.skip("node not installed")
    root = Path(__file__).resolve().parents[1]
    a, now = _arrivals(static)
    # a fitted model (real tables, shrunk) rather than a synthetic one: the port must read the published shape
    rng = np.random.default_rng(3)
    es = pd.DataFrame([{"trip_key": r["trip_key"], "route_id": r["route_id"], "stop_id": r["stop_id"], "at_stop": "x", "at_ts": r["arrival_ts"] - 35 - h,
                        "stops_ahead": 2, "eta_ts": r["arrival_ts"] - 35 + float(rng.normal(0, 20)) + 0.25} for _, r in a.head(800).iterrows() for h in (100, 700, 2000)])
    tt = pd.DataFrame([{"trip_key": r["trip_key"], "route_id": r["route_id"], "stop_id": r["stop_id"], "at_stop": "x", "at_ts": r["arrival_ts"] - h,
                        "stops_ahead": 2, "eta_ts": float(np.floor((r["arrival_ts"] + 100 + float(rng.normal(0, 30))) / 30) * 30)}
                       for _, r in a.iloc[800:1100].iterrows() for h in (100, 700)])
    es = pd.concat([es, tt], ignore_index=True)
    dw = pd.DataFrame({"trip_key": [f"t{i}" for i in range(120)], "route_id": "6", "direction": "N", "stop_id": "633N", "stopped_from_ts": 1.0, "stopped_to_ts": 2.0,
                       "dwell_sec": np.r_[np.full(60, 220.0), np.full(40, 500.0), np.full(20, 1300.0)], "polls": 3})
    model = cm.fit_client_model(es, a, dw, static, "2026-01-01")
    assert model["eta_calibration"]["timetable"]["n"] == len(tt)
    line = _line()
    trains = [_train("held", 3, now, lateness=60.0, eff=250.0, sched=now + 40, pos={"status": "STOPPED_AT", "since_sec": 330, "holding": True, "stalled": False}),
              _train("follower", 1, now, lateness=-20.0, sched=now + 80), _train("leader", 6, now, lateness=400.0, eff=400.0, sched=now + 30, step=80.0),
              _train("nosched", 2, now, lateness=None, eff=None), _train("twin", 1, now, lateness=30.0, sched=now + 95, step=110.0),
              dict(_train("timetable", 4, now, lateness=0.0, eff=200.0, sched=now + 60, pos={"status": "STOPPED_AT", "since_sec": 400, "holding": True, "stalled": False}),
                   timetable=True)]
    trains[3]["effective_lateness_sec"] = None
    inp = {"trains": trains, "line": line, "model": model, "now": now, "scenarios": list(cm.SCENARIOS), "elapsed": [100, 200, 330, 1000, 5000], "horizons": [-10, 0, 150, 700, 9000]}
    (tmp_path / "in.json").write_text(json.dumps(inp))
    mod = tmp_path / "rt-client.mjs"; shutil.copy(root / "site" / "rt-client.js", mod)
    (tmp_path / "h.mjs").write_text(PREDICT_HARNESS % mod.as_uri())
    js = json.loads(subprocess.run(["node", str(tmp_path / "h.mjs"), str(tmp_path / "in.json")], capture_output=True, text=True, check=True).stdout)
    for sc in cm.SCENARIOS:
        py = cm.predict_line(trains, line, model, now, sc)
        assert [t["trip_id"] for t in js[sc]["trains"]] == [t["trip_id"] for t in py["trains"]]
        for tj, tp in zip(js[sc]["trains"], py["trains"]):
            assert tj["hold_extra_sec"] == pytest.approx(tp["hold_extra_sec"], abs=1e-6) and tj["knock_on_sec"] == pytest.approx(tp["knock_on_sec"], abs=1e-6)
            assert len(tj["points"]) == len(tp["points"])
            for pj, pp in zip(tj["points"], tp["points"]):
                assert pj["idx"] == pp["idx"] and pj["source"] == pp["source"]
                for f in ("eta_ts", "lo_ts", "hi_ts"):
                    assert pj[f] == pytest.approx(pp[f], abs=1e-6)
        assert js[sc]["n_knock_on"] == py["n_knock_on"] and js[sc]["knock_on_total_sec"] == pytest.approx(py["knock_on_total_sec"], abs=1e-6)
        assert (js[sc]["worst_gap"] or {}).get("idx") == (py["worst_gap"] or {}).get("idx")
        assert [s["n_arrivals"] for s in js[sc]["per_stop"]] == [s["n_arrivals"] for s in py["per_stop"]]
    for e, rj in zip(inp["elapsed"], js["rem"]):
        rp = cm.remaining_hold(model["hold_survival"], e)
        assert all(rj[k] == pytest.approx(rp[k], abs=1e-6) for k in ("expected", "p50", "p90", "clears_2min"))
    for h, cj in zip(inp["horizons"], js["cal"]):
        assert cj == cm.calibration_at(model, "6", h)
    for h, cj in zip(inp["horizons"], js["ttcal"]):
        assert cj == cm.calibration_at(model, "6", h, timetable=True)
    assert js["grid"] == [cm.is_timetable_trip([1020, 1140, 1290, 1380]), cm.is_timetable_trip([1020, 1141, 1290]),
                          cm.is_timetable_trip([1020, 1140]), cm.is_timetable_trip([1020])] == [True, False, True, False]
    # the scenarios differ where they should
    e5 = lambda out, tid: next(pt["eta_ts"] for t in out["trains"] if t["trip_id"] == tid for pt in t["points"] if pt["idx"] == 5)
    assert e5(js["clears_now"], "held") < e5(js["baseline"], "held") < e5(js["hold_persists"], "held")


def test_timetable_trips_get_their_own_calibration_and_no_carry_or_hold(static):
    """A trip the feed only plays the timetable for: every stop time on the half-minute grid (Nov 4 2026: a G from
    Church Av "stopped" on the half minute at every station and came into 4 Av-9 St minutes before its time)."""
    assert cm.is_timetable_trip([1020.0, 1140.0, 1290.0, 1380.0])
    assert not cm.is_timetable_trip([1020.0, 1141.0, 1290.0])
    assert cm.is_timetable_trip([1020.0, 1140.0]) and not cm.is_timetable_trip([1020.0])
    assert not cm.is_timetable_trip([1024.0, 1144.0, 1294.0])
    a, _ = _arrivals(static)
    a = a.head(600).copy()
    rows = []
    for i, (_, r) in enumerate(a.iterrows()):
        if i % 2:   # tracked: to the second, 10 s late
            rows.append({"trip_key": r["trip_key"], "route_id": r["route_id"], "stop_id": r["stop_id"], "at_stop": "x", "at_ts": r["arrival_ts"] - 500,
                         "stops_ahead": 3, "eta_ts": r["arrival_ts"] - 10.0 + 0.5})
        else:       # timetable: on the grid, the train 120 s ahead of it
            eta = math.floor((r["arrival_ts"] + 120) / 30) * 30
            rows.append({"trip_key": r["trip_key"], "route_id": r["route_id"], "stop_id": r["stop_id"], "at_stop": "x", "at_ts": eta - 500,
                         "stops_ahead": 3, "eta_ts": float(eta)})
    cal = cm.fit_eta_calibration(pd.DataFrame(rows), a)
    assert cal["timetable"]["n"] == 300 and cal["n"] == 300
    assert cal["timetable"]["all"][2]["bias"] < -80 and abs(cal["all"][2]["bias"] - 9.5) < 2
    model = _model(bias=0.0, slope=1.0, intercept=200.0)
    model["eta_calibration"]["timetable"] = {"n": 50, "all": [{"n": 50, "bias": -90.0, "p10": -160.0, "p90": 20.0}] * (len(cm.HORIZON_EDGES) - 1), "by_route": {}}
    assert cm.calibration_at(model, "6", 400, timetable=True)["bias"] == -90.0 and cm.calibration_at(model, "6", 400)["bias"] == 0.0
    now = 1_000_000.0
    held = {"status": "STOPPED_AT", "since_sec": 400, "holding": True, "stalled": False}
    t = _train("tt", 2, now, lateness=0.0, eff=150.0, sched=now + 60, pos=held)
    tracked = cm.predict_train(t, _line(), model, now)
    tt = cm.predict_train({**t, "timetable": True}, _line(), model, now)
    assert tracked["hold_extra_sec"] > 0 and tt["hold_extra_sec"] == 0.0
    assert all(p["source"] == "feed" for p in tt["points"])
    for p in tt["points"]:
        assert p["eta_ts"] == pytest.approx(max(now, p["feed_ts"] - 90.0)) or p["eta_ts"] >= now
        assert p["lo_ts"] <= p["eta_ts"] - 50
