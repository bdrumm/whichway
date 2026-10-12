"""The station-stop corpus: stops read from a motion trace by the train's push, named in order from the train's
recorded arrivals."""
from __future__ import annotations

import pytest

from mta_delay_insights import corpus as c


def _trace(t0, pattern):
    """seconds from (kind, n) runs: 'push' braking or pulling away, 'stand' at a platform (doors: some shake), 'cruise'
    rolling between stations (low push, some shake), 'walk'."""
    rows, t = [], t0
    for kind, n in pattern:
        for _ in range(n):
            step = 0.05 if kind == "walk" else 0.001
            push = 0.09 if kind == "push" else (0.02 if kind == "cruise" else 0.008)
            shake = 0.03 if kind in ("cruise", "push") else 0.05      # a platform is no quieter than the run
            rows.append([t, step, push, shake])
            t += 1
    return {"columns": ["ts", "stepEnergy", "pushG", "shakeG"], "seconds": rows}


def test_stops_are_read_from_the_push_not_the_shake():
    t0 = 1000.0
    tr = _trace(t0, [("stand", 10), ("push", 6), ("cruise", 60), ("push", 6), ("stand", 25), ("push", 6), ("cruise", 50),
                     ("push", 5), ("stand", 15), ("walk", 12)])
    felt = c.felt_stops_from_trace(tr, [{"kind": "departed", "ts": t0 + 10}, {"kind": "alighted", "ts": t0 + 183}])
    spans = [(s.start, s.end, s.alighting) for s in felt[0]]
    # the stand from the end of the braking to the pull-away, and the walk-off stop; the cruises between pushes come
    # back as candidates too (the push alone cannot tell coasting from standing), for the alignment to leave over
    assert (t0 + 82, t0 + 107, False) in spans
    assert spans[-1] == (t0 + 168, None, True)
    assert all(not a or e is None for _, e, a in spans)


def test_felt_stops_are_named_in_order_and_a_lull_is_left_over():
    st = [c.Station("S1", "One", 1100, 1100), c.Station("S2", "Two", 1220, 1220), c.Station("S3", "Three", 1340, 1340)]
    felt = [c.Span(1110, 1130), c.Span(1180, 1190), c.Span(1215, 1240), c.Span(1350, None, True)]   # a lull at 1180
    m = c.align(felt, st)
    named = {mt.felt: mt.station for mt in m if mt.felt is not None and mt.station is not None}
    assert named == {0: 0, 2: 1, 3: 2}
    assert any(mt.felt == 1 and mt.station is None for mt in m)
    # nothing is matched past the gate, and the walk-off stop can only be the last station
    far = c.align([c.Span(1100 + c.GATE_SEC + 30, 1200)], st[:1])
    assert all(mt.station is None or mt.felt is None for mt in far)
    off = c.align([c.Span(1105, None, True)], st)
    assert not any(mt.felt == 0 and mt.station is not None for mt in off)


def test_the_summary_measures_the_lag_and_the_dwell():
    import pandas as pd
    rows = [{"trip_id": "t", "route": "F", "kind": "station", "lag_sec": l, "dwell_sec": d, "sure": True} for l, d in ((70, 20), (80, 30), (90, None))]
    rows.append({"trip_id": "t", "route": "F", "kind": "unfelt"})
    s = c.summarize(pd.DataFrame(rows))
    f = s["lines"]["F"]
    assert f["lag_sec_p50"] == pytest.approx(80) and f["dwell_sec_p50"] == pytest.approx(25) and f["felt_share"] == pytest.approx(0.75)
