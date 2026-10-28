"""Rider reports checked against the record, reporter trust, the detector fit and the ETA feature test."""
from __future__ import annotations

import json

import numpy as np
import pandas as pd

from mta_delay_insights.analysis import rider_reports as rr

T0 = 1_792_000_000.0   # 2026-10-15 ~ 13:46 New York (midday)


def arrivals(route="A", stop="A41S", every=300, start=T0 - 7200, end=T0 + 7200, gap=None):
    ts = list(np.arange(start, end, every))
    if gap:
        ts = [t for t in ts if not (gap[0] < t < gap[1])]
    return pd.DataFrame({"trip_key": [f"t{i}" for i in range(len(ts))], "route_id": route, "direction": "S", "stop_id": stop, "arrival_ts": ts})


def holds(dwell, at=T0 - 60, route="A", stop="A41S"):
    return pd.DataFrame({"trip_key": ["h1"], "route_id": [route], "direction": ["S"], "stop_id": [stop], "stopped_from_ts": [at], "stopped_to_ts": [at + dwell], "dwell_sec": [dwell]})


def report(kind, ts=T0, stop="A41", rider="r1", reporter=None, **kw):
    return {"id": f"{kind}-{ts}-{rider}", "ts": ts, "kind": kind, "route": "A", "dir": "S", "stop": stop, "rider": rider, "reporter": reporter, **kw}


def test_held_report_backed_by_a_hold_and_contradicted_without_one():
    reps = pd.DataFrame([report("held")])
    assert rr.verify(reps, arrivals(), holds(240)).iloc[0]["verdict"] == "backed"
    assert rr.verify(reps, arrivals(), holds(40)).iloc[0]["verdict"] == "contradicted"
    # no record of the line there at all: no judgement
    assert rr.verify(reps, arrivals(stop="D20S"), pd.DataFrame()).iloc[0]["verdict"] == "unverified"


def test_long_wait_and_all_good_read_the_gap():
    a = arrivals(gap=(T0 - 900, T0 + 900))          # a 30 min hole in 5 min service
    v = rr.verify(pd.DataFrame([report("long_wait"), report("all_good", rider="r2")]), a, pd.DataFrame())
    assert list(v["verdict"]) == ["backed", "contradicted"]
    assert rr.verify(pd.DataFrame([report("long_wait")]), arrivals(), pd.DataFrame()).iloc[0]["verdict"] == "contradicted"
    assert rr.verify(pd.DataFrame([report("crowded", sub="packed")]), arrivals(), pd.DataFrame()).iloc[0]["verdict"] == "unmeasured"


def test_trust_rises_with_backed_reports_and_falls_with_contradicted_ones():
    v = pd.DataFrame([{"id": str(i), "reporter": "good", "rider": "x", "verdict": "backed"} for i in range(5)]
                     + [{"id": f"b{i}", "reporter": "bad", "rider": "y", "verdict": "contradicted"} for i in range(5)])
    t = rr.reporter_trust(v).set_index("who")["trust"]
    assert t["good"] > 0.8 and t["bad"] < 0.2


def test_detector_fit_moves_the_gap_threshold_toward_the_riders():
    # riders call a wait long from 2x the headway; the detector in use waits for 2.5x
    rows = []
    for i, ratio in enumerate(np.linspace(1.0, 4.0, 40)):
        rows.append({"id": str(i), "kind": "long_wait" if ratio >= 2.0 else "all_good", "wait_sec": ratio * 300, "headway_sec": 300.0,
                     "band": "midday", "covered": True, "hold_sec": None, "reporter": None, "rider": f"r{i}"})
    fit = rr.detector_fit(pd.DataFrame(rows), pd.DataFrame(columns=["who", "trust"]))
    g = fit["gap"]["midday"]
    assert fit["mode"] == "shadow" and g["ready"]
    assert 1.9 <= g["fitted"] <= 2.1 and g["f1_fitted"] > g["f1_current"]


def test_eta_feature_adopted_only_when_it_lowers_held_out_error():
    rng = np.random.default_rng(1)
    n = 600
    at = T0 + np.arange(n) * 30.0
    reps = pd.DataFrame([report("held", ts=t - 60, rider=f"r{i}") for i, t in enumerate(at[::3])])
    es = pd.DataFrame({"trip_key": [f"k{i}" for i in range(n)], "route_id": "A", "stop_id": "A41S", "at_stop": "A40S", "at_ts": at, "stops_ahead": 1, "eta_ts": at + 120})
    trust = pd.DataFrame(columns=["who", "trust"])
    p = rr.report_pressure(reps, trust, np.array(["A"] * n), at)
    late = 90 * p + rng.normal(0, 20, n)          # the countdown runs late by 90 s per report on the line
    arr = pd.DataFrame({"trip_key": es["trip_key"], "stop_id": "A41S", "arrival_ts": es["eta_ts"] + late})
    res = rr.eta_feature_test(es, arr, reps, trust)
    assert res["status"] == "adopt" and 60 < res["sec_per_report"] < 120
    arr2 = arr.assign(arrival_ts=es["eta_ts"] + rng.normal(0, 60, n))
    assert rr.eta_feature_test(es, arr2, reps, trust)["status"] == "reject"


def test_reports_are_kept_once(tmp_path):
    p = tmp_path / "reports" / "reports.jsonl"
    assert rr.merge_reports(p, [report("held"), report("held"), {"id": "x", "kind": "nonsense"}]) == 1
    assert rr.merge_reports(p, [report("held"), report("all_good")]) == 1
    df = rr.load_reports(p)
    assert len(df) == 2
    fb = rr.feedback(df, arrivals(), holds(200), None, T0 + 600)
    assert fb["n"] == 2 and fb["verdicts"].get("backed", 0) >= 1
    json.dumps(fb, default=str)
