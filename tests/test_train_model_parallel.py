"""The trainer's per-day row build: one worker process per day gives the same rows as the serial build."""
from __future__ import annotations

import pickle
from datetime import timedelta

import numpy as np
import pandas as pd
import pytest

pytest.importorskip("pyarrow")

from mta_delay_insights import synthetic  # noqa: E402
from mta_delay_insights.lake import MAC, Lake, local_day  # noqa: E402
from mta_delay_insights.models.context import FeatureContext  # noqa: E402
from mta_delay_insights.storage.db import Store  # noqa: E402
from pipeline import train_model as tm  # noqa: E402
from tests.conftest import START  # noqa: E402

K_SET = (1, 3, 5)


@pytest.fixture(scope="module")
def sim(static):
    sc = synthetic.Scenario("t", START, START + timedelta(days=2), START + timedelta(days=5), issues=list(synthetic.SCENARIOS["mixed"]), directions=("N", "S"))
    out = synthetic.simulate(static, sc)
    out.arrivals["source"] = "rt_dropoff"
    return out


def _eta_samples(arr: pd.DataFrame) -> pd.DataFrame:
    """The feed's forecasts for a stop three ahead, so the shared ETA table reaches the rows (feed_excess)."""
    a = arr.sort_values(["trip_key", "arrival_ts"])
    nxt = a.groupby("trip_key").shift(-3)
    ok = nxt["stop_id"].notna().values
    rng = np.random.default_rng(3)
    return pd.DataFrame({"trip_key": a["trip_key"].values[ok], "route_id": a["route_id"].values[ok], "stop_id": nxt["stop_id"].values[ok],
                         "at_stop": a["stop_id"].values[ok], "at_ts": a["arrival_ts"].values[ok] - 30, "stops_ahead": 3,
                         "eta_ts": nxt["arrival_ts"].values[ok] + rng.normal(0, 40, ok.sum())})


def _source(kind: str, sim, tmp_path):
    """A day loader over a synthetic lake or data branch, and the ETA samples read back the way the trainer reads them."""
    if kind == "lake":
        lake = Lake(tmp_path / "lake")
        lake.write_days("arrivals", MAC, sim.arrivals)
        lake.write_days("eta_samples", MAC, _eta_samples(sim.arrivals))
        return tm.LakeArrivals(lake.root), lake.eta_samples()
    # the branch path's day files are read from CSV, which turns the synthetic routes ("4", "6") into integers, so
    # the days come from the store here: the parent's open store stays behind and each worker opens the file read-only
    db = tmp_path / "store.sqlite"
    st = Store(db)
    st.insert_arrivals(sim.arrivals)
    st.insert_eta_samples(_eta_samples(sim.arrivals))
    st.close()
    parent = Store(db)
    eta = parent.eta_samples(None, None, None).drop_duplicates(["trip_key", "stop_id", "at_stop"], keep="first")
    return tm.BranchArrivals(tmp_path / "branch", db, store=parent), eta


@pytest.mark.parametrize("kind", ["lake", "branch"])
def test_parallel_row_build_equals_serial(static, sim, tmp_path, kind):
    loader, eta = _source(kind, sim, tmp_path)
    fc = FeatureContext.build(alerts_df=sim.alerts, weather_daily=sim.weather_daily)
    sim_days = sorted(sim.arrivals["arrival_ts"].map(local_day).unique())
    # a day without arrivals first (skipped, it keeps its manifest place), then three days with both neighbours
    days = [sim_days[0] - timedelta(days=3)] + sim_days[1:4]
    args = (days, loader, static, fc, eta, K_SET, 0.5, 7)
    serial, sman = tm.build_rows_for_days(*args, min_arrivals=500, jobs=1)
    par, pman = tm.build_rows_for_days(*args, min_arrivals=500, jobs=2)
    assert len(serial) > 2000 and list(serial["day"].unique()) == [d.isoformat() for d in days[1:]]
    assert serial["feed_excess"].notna().any()
    pd.testing.assert_frame_equal(serial, par, check_exact=True)
    # the same values, dtypes, columns and index; the pickles' bytes are not compared: block layout and memo order
    # differ across pandas versions (CI's 3.10-3.12 vs this Mac's) even for identical frames
    assert list(serial.dtypes) == list(par.dtypes) and serial.index.equals(par.index)
    drop = lambda man: [{k: v for k, v in m.items() if k != "seconds"} for m in man]  # noqa: E731
    assert drop(sman) == drop(pman)
    assert [m["day"] for m in pman] == [d.isoformat() for d in days] and pman[0]["skipped"]


def test_loaders_pickle_without_handles(sim, tmp_path):
    lake_loader, _ = _source("lake", sim, tmp_path)
    d = sorted(sim.arrivals["arrival_ts"].map(local_day).unique())[1]
    first = lake_loader(d)                     # opens its Lake
    again = pickle.loads(pickle.dumps(lake_loader))
    assert again._lake is None
    pd.testing.assert_frame_equal(first, again(d))
    store_loader = tm.BranchArrivals(tmp_path / "branch", None, store=object())
    assert pickle.loads(pickle.dumps(store_loader))._store is None


def test_default_jobs_bounds():
    assert tm.default_jobs(1) == 1
    assert 1 <= tm.default_jobs(10_000) <= (__import__("os").cpu_count() or 1)
    assert tm.default_jobs(3) <= 3
