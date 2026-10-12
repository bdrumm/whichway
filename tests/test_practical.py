"""Practical lateness: the extra wait a train makes (its gap behind the one before over the scheduled headway), not
the minutes behind a timetable the whole line has slid from."""
from __future__ import annotations

import pandas as pd
import pytest

from mta_delay_insights.analysis import phases as ph
from mta_delay_insights.realtime import status as st


def _arrivals(stop, times, sched):
    return pd.DataFrame({"route_id": "C", "stop_id": stop, "arrival_ts": times, "sched_arrival_ts": sched, "trip_key": [f"t{i}" for i in range(len(times))]})


def test_an_even_slide_off_the_timetable_is_no_extra_wait_but_a_dropped_train_is():
    t0, H = 1_700_000_000.0, 480.0
    sched = [t0 + i * H for i in range(12)]
    # every train 15 min behind its timetable, at the timetable's spacing
    slid = ph.stop_gap_bins(_arrivals("A41N", [s + 900 for s in sched], sched))
    assert len(slid) and slid["lateness_sec"].max() < 60
    # the 6th trip dropped: the 7th arrives a whole headway after riders expected a train
    times = [s + 900 for i, s in enumerate(sched) if i != 5]
    gaps = ph.stop_gap_bins(_arrivals("A41N", times, [s for i, s in enumerate(sched) if i != 5]))
    assert gaps["lateness_sec"].max() == pytest.approx(H, abs=1)


def test_a_hold_reads_while_the_wait_is_still_open():
    t0, H = 1_700_000_000.0, 300.0
    sched = [t0 + i * H for i in range(10)]
    times = sched[:6] + [sched[6] + 1200] + [s + 1200 for s in sched[7:]]    # held 20 min before the 7th
    b = ph.stop_gap_bins(_arrivals("A40N", times, sched))
    during = b[(b["bin"] * 300 > sched[5] + H) & (b["bin"] * 300 < times[6] - 300)]
    assert len(during) and (during["lateness_sec"] > 0).all() and (during["n"] >= ph.MIN_TRAINS).all()
    assert b["lateness_sec"].max() == pytest.approx(times[6] - times[5] - H, abs=1)


def test_each_train_is_judged_on_its_gap_behind_the_train_before(monkeypatch):
    now = 1_700_000_000.0
    monkeypatch.setattr(st, "_sched_headway", lambda *a, **k: 480.0)
    def train(tid, etas, started=True):
        return st.LiveTrain(trip_id=tid, route_id="C", direction="N", start_date=None, feed="ace", stops=[(s, now + e) for s, e in etas], started=started,
                            lateness_sec=900.0)
    lead = train("a", [("A41N", 60), ("A40N", 180)])
    even = train("b", [("A41N", 540), ("A40N", 660)])          # 8 min behind it: the scheduled spacing
    gap = train("c", [("A41N", 1140), ("A40N", 1260)])         # 10 min behind that: 2 min of extra wait
    far = train("d", [("A41N", 1900), ("A40N", 2020)])         # due past the 20 min the feed's times are good for
    st.annotate_practical([lead, even, gap, far], static=None, now=now)
    assert lead.practical_lateness_sec is None                 # nothing ahead of it on the board
    assert even.practical_lateness_sec == pytest.approx(0)
    assert gap.practical_lateness_sec == pytest.approx(120)
    assert far.practical_lateness_sec is None
    assert even.as_dict()["practical_lateness_sec"] == pytest.approx(0)
