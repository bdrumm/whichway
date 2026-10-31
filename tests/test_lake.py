"""The lake: the gatherers' output kept on the Mac, synced from a branch tree, the archive and the store."""
from __future__ import annotations

import subprocess
import time
from datetime import date, timedelta

import numpy as np
import pandas as pd
import pytest

pytest.importorskip("pyarrow")

from mta_delay_insights import lake as lk  # noqa: E402
from mta_delay_insights import synthetic  # noqa: E402
from mta_delay_insights.lake import ACTION, ARCHIVE, MAC, DirTree, GitTree, Lake  # noqa: E402
from mta_delay_insights.sources.gtfs_static import service_midnight  # noqa: E402
from mta_delay_insights.storage.db import Store  # noqa: E402
from pipeline import lib  # noqa: E402
from tests.conftest import START  # noqa: E402

DAYS = 5


def _sim(static):
    sc = synthetic.Scenario("t", START, START + timedelta(days=2), START + timedelta(days=DAYS), issues=list(synthetic.SCENARIOS["signal"]), directions=("N", "S"))
    return synthetic.simulate(static, sc)


def _local_days(arr: pd.DataFrame) -> pd.Series:
    return arr["arrival_ts"].map(lk.local_day)


def _eta_samples(a: pd.DataFrame) -> pd.DataFrame:
    rng = np.random.default_rng(2)
    rows = []
    for _, r in a.head(300).iterrows():
        for h in (100, 700):
            rows.append({"trip_key": r["trip_key"], "route_id": r["route_id"], "stop_id": r["stop_id"], "at_stop": f"x{h}", "at_ts": r["arrival_ts"] - 35 - h,
                         "stops_ahead": 2, "eta_ts": r["arrival_ts"] - 35 + float(rng.normal(0, 20))})
    return pd.DataFrame(rows)


def _dwells(a: pd.DataFrame) -> pd.DataFrame:
    g = a.head(90).copy()
    return pd.DataFrame({"trip_key": g["trip_key"].values, "route_id": g["route_id"].values, "direction": g["direction"].values, "stop_id": g["stop_id"].values,
                         "stopped_from_ts": g["arrival_ts"].values, "stopped_to_ts": g["arrival_ts"].values + np.tile([40.0, 200.0, 400.0], 30),
                         "dwell_sec": np.tile([40.0, 200.0, 400.0], 30), "polls": 3})


def make_lake(static, tmp_path, monkeypatch=None):
    """A data directory laid out like the branch (archive days first, collector days last) and a store with the
    collector days, synced into a fresh lake. Returns (lake, sim, data_dir, store_path, days)."""
    sim = _sim(static)
    arr = sim.arrivals.copy()
    days = sorted(_local_days(arr).unique())
    cut = service_midnight(days[3]).timestamp()
    net = arr[arr["arrival_ts"] < cut].copy(); net["source"] = "subwaydata"; net["train_id"] = "06 0000  BBR/PEL"
    net["start_date"] = _local_days(net).map(lambda d: d.strftime("%Y%m%d"))
    own = arr[arr["arrival_ts"] >= cut].copy(); own["source"] = "rt_dropoff"
    data_dir = tmp_path / "branch"; data_dir.mkdir()
    lib.save_network_arrivals(data_dir, net)
    lib.save_network_arrivals(data_dir, own)
    lib.save_arrivals(data_dir, own.head(500))
    es = _eta_samples(own)
    lib.save_eta_samples(data_dir, es)
    dw = _dwells(own)
    lib.save_holds(data_dir, dw[dw["dwell_sec"] >= 150])
    lib.save_dwells(data_dir, dw)
    lib.save_alerts(data_dir, sim.alerts, seen_ts=float(sim.alerts["active_start"].max()))
    lib.save_context(data_dir, "weather_daily", sim.weather_daily)
    lib.append_run(data_dir, {"kind": "collect", "polls": 3})
    store_path = tmp_path / "store.sqlite"
    st = Store(store_path)
    st.insert_arrivals(own)
    st.insert_eta_samples(es)
    st.insert_dwells(dw)
    for i in range(10):
        st.insert_snapshot("ace", cut + 30 * i, cut + 30 * i - 2, 100, 50, 5)
    fe = pd.DataFrame({"made_ts": [cut + 100, cut + 86400 + 100], "target_id": "t", "stop_id": "631N", "trip_id": ["a", "b"], "route_id": "6", "horizon_sec": 300.0,
                       "feed_eta_ts": cut + 400, "model_eta_ts": cut + 410, "model_source": "learned", "sim_eta_ts": cut + 405, "hold_eta_ts": np.nan,
                       "corroboration": "none", "holding": 0, "stalled": 0, "stops_away": 3, "arrival_ts": cut + 420, "feed_err_sec": 20.0, "model_err_sec": 10.0, "sim_err_sec": 15.0})
    st.put_frame("forecast_eval", fe)
    st.upsert_alerts(sim.alerts, seen_ts=float(sim.alerts["active_start"].max()) + 600)
    st.put_frame("goodservice", pd.DataFrame({"ts": [cut], "route": ["6"], "status": ["Good Service"]}))
    st.close()
    if monkeypatch is not None:
        monkeypatch.setattr(lk, "ARCHIVE_FULL_DAY", 10)
        monkeypatch.setattr(lk, "SERVICE_DAY_FULL", 10)
        monkeypatch.setattr(lk, "SERVICE_DAY_SPILL", 1)
    lake = Lake(tmp_path / "lake")
    rep = lake.sync(tree=DirTree(data_dir), db=store_path, archive_days=0)
    return lake, sim, data_dir, store_path, days, rep


def test_sync_branch_tree_and_store(static, tmp_path, monkeypatch):
    lake, sim, data_dir, store_path, days, rep = make_lake(static, tmp_path, monkeypatch)
    assert rep["branch"]["files"] > 5 and rep["branch"]["rows"] > 0 and rep["store"]["tables"]["arrivals"]["days"] >= 2
    # archive days land as the archive source, the collector's as action (branch) and mac (store)
    assert set(lake.days("arrivals", ARCHIVE)) >= set(days[:3])
    assert set(lake.days("arrivals", ACTION)) >= set(days[3:5]) and set(lake.days("arrivals", MAC)) >= set(days[3:5])
    first = lake.arrivals(days[0])
    assert len(first) > 10 and (first["source"] == "subwaydata").all() and first["start_date"].iloc[0] == days[0].strftime("%Y%m%d")
    assert lake.arrival_source(days[0]) == ARCHIVE and lake.arrival_source(days[4]) == "collector"
    last = lake.arrivals(days[4])
    assert len(last) > 10 and (last["source"] != "subwaydata").all() and not last.duplicated(["trip_key", "stop_id"]).any()
    assert len(lake.arrivals(days[4], prefer_archive=False)) == len(last)
    # the same ETA samples came through the branch and the store: one copy
    es = lake.eta_samples()
    assert len(es) == 600 and not es.duplicated(["trip_key", "stop_id", "at_stop"]).any()
    # holds: the branch's hold log and the store's dwells over the threshold, deduped
    h = lake.holds()
    assert len(h) == 60 and (h["dwell_sec"] >= 150).all()
    assert len(lake.dwells()) == 90
    al = lake.alerts()
    assert len(al) == len(sim.alerts) and al["planned"].dtype == bool and isinstance(al.iloc[0]["routes"], list)
    # the store's later last-seen wins over the branch's save-time stamp
    assert al["last_seen_ts"].max() >= float(sim.alerts["active_start"].max()) + 600
    assert (lake.root / "context" / "weather_daily.csv.gz").exists() and lib.load_context(lake.root, "weather_daily") is not None
    assert (lake.root / "alerts" / "mac.parquet").exists() and (lake.root / "context" / "goodservice.parquet").exists()
    assert set(lake.days("forecast_eval", MAC)) == {days[3], days[4]} and set(lake.days("snapshots", MAC)) == {days[3]}
    cov = lake.coverage()
    assert cov["span"]["first"] == days[0].isoformat() and cov["archive_days"] == 3 and cov["arrival_gaps"] == []
    assert set(cov["tables"]["arrivals"]) == {ARCHIVE, ACTION, MAC}
    txt = lake.status_text()
    assert "arrivals" in txt and days[4].isoformat() in txt and "collector" in txt
    # a second sync does nothing: every blob is known and no store day changed
    rep2 = lake.sync(tree=DirTree(data_dir), db=store_path, archive_days=0)
    assert rep2["branch"]["files"] == 0 and rep2["branch"]["skipped"] > 5
    assert all(v.get("days", 0) == 0 for k, v in rep2["store"]["tables"].items() if k in lk.STORE_DAY_TABLES)
    # ... but new rows in the store re-export the day they fall on
    st = Store(store_path)
    extra = sim.arrivals.tail(5).copy(); extra["trip_key"] = extra["trip_key"] + "|x"; extra["source"] = "rt_dropoff"
    st.insert_arrivals(extra); st.close()
    rep3 = lake.sync(tree=DirTree(data_dir), db=store_path, archive_days=0)
    assert rep3["store"]["tables"]["arrivals"]["days"] >= 1


def test_duckdb_views(static, tmp_path, monkeypatch):
    pytest.importorskip("duckdb")
    lake, sim, _, _, days, _ = make_lake(static, tmp_path, monkeypatch)
    df = lake.sql("select source, count(*) as n from arrivals group by 1 order by 1")
    assert set(df["source"]) == {ARCHIVE, ACTION, MAC}
    by_day = lake.sql(f"select count(*) as n from arrivals where day = '{days[0].isoformat()}' and source = 'archive'")
    assert int(by_day["n"].iloc[0]) == len(lake.arrivals(days[0]))


def test_archive_fetch_merge_and_retry(static, tmp_path, monkeypatch):
    monkeypatch.setattr(lk, "SERVICE_DAY_FULL", 10)
    monkeypatch.setattr(lk, "SERVICE_DAY_SPILL", 1)
    sim = _sim(static)
    arr = sim.arrivals.copy(); arr["source"] = "subwaydata"
    days = sorted(_local_days(arr).unique())
    today = days[-1] + timedelta(days=1)

    def fetch(sd: date) -> pd.DataFrame:
        # a service day: its own local day plus a few rows spilling past midnight into the next
        if sd == days[1]:
            out = pd.DataFrame(columns=arr.columns); out.attrs["error"] = "404"; return out
        lo, hi = lk.day_bounds(sd)
        own = arr[(arr["arrival_ts"] >= lo) & (arr["arrival_ts"] < hi)].copy()
        spill = arr[(arr["arrival_ts"] >= hi) & (arr["arrival_ts"] < hi + 3600)].head(5).copy()
        out = pd.concat([own, spill], ignore_index=True)
        out["start_date"] = sd.strftime("%Y%m%d")
        return out

    lake = Lake(tmp_path / "lake")
    wanted = lake.archive_wanted(DAYS, today=today)
    assert wanted == [today - timedelta(days=i) for i in range(1, DAYS + 1)]
    rep = lake.sync_archive(DAYS, max_fetch=2, fetch=fetch, pause_sec=0, today=today)
    assert [f["day"] for f in rep["fetched"]] == [days[-1].isoformat(), days[-2].isoformat()] and rep["wanted"] == DAYS
    assert lake.service_day_covered(days[-1]) is False       # its spill-over day is not in the window: nothing vouches for it
    assert lake.service_day_covered(days[-2]) is True
    rep = lake.sync_archive(DAYS, max_fetch=10, fetch=fetch, pause_sec=0, today=today)
    assert days[1].isoformat() in rep["failed"]
    # the day that 404'd is young, so it is wanted again at the next sync; once old it waits a month
    assert days[1] in lake.archive_wanted(DAYS, today=today)
    assert days[1] not in lake.archive_wanted(DAYS + 30, today=today + timedelta(days=30))
    lake.manifest["archive"][days[1].isoformat()]["at"] = time.time() - lk.RETRY_OLD_SEC - 1
    assert days[1] in lake.archive_wanted(DAYS + 30, today=today + timedelta(days=30))
    # the spill rows merged into the next day's partition beside that day's own rows: no duplicates, both service days noted
    nxt = lake.read("arrivals", days[-2], ARCHIVE)
    assert not nxt.duplicated(["trip_key", "stop_id"]).any() and set(nxt["start_date"]) == {days[-3].strftime("%Y%m%d"), days[-2].strftime("%Y%m%d")}
    assert set(lake.manifest["service_days"][days[-2].isoformat()]) == {days[-3].isoformat(), days[-2].isoformat()}
    # writing a day again changes nothing
    n = lake.write("arrivals", days[-2], ARCHIVE, nxt)
    assert n == len(nxt)


def test_git_tree_reads_the_branch_objects(tmp_path):
    repo = tmp_path / "repo"; repo.mkdir()
    run = lambda *a: subprocess.run(["git", "-C", str(repo), *a], check=True, capture_output=True, text=True)  # noqa: E731
    run("init", "-q", "-b", "data")
    run("config", "user.email", "t@example.com"); run("config", "user.name", "t")
    (repo / "context").mkdir()
    pd.DataFrame({"date": ["2026-09-01"], "precip_mm": [1.0]}).to_csv(repo / "context" / "weather_daily.csv.gz", index=False, compression="gzip")
    (repo / "runs.json").write_text("[]")
    run("add", "-A"); run("commit", "-q", "-m", "one")
    tree = GitTree(repo, "data")
    files = tree.files()
    assert set(files) == {"context/weather_daily.csv.gz", "runs.json"} and files["runs.json"][1] == 2
    assert tree.read(files["runs.json"][0]) == b"[]"
    lake = Lake(tmp_path / "lake")
    rep = lake.sync_tree(tree, fetch=False)
    assert rep["files"] == 2 and (lake.root / "context" / "weather_daily.csv.gz").exists()
    (repo / "runs.json").write_text("[1]")
    run("commit", "-qam", "two")
    rep = lake.sync_tree(GitTree(repo, "data"), fetch=False)
    assert rep["files"] == 1 and rep["skipped"] == 1 and (lake.root / "branch" / "runs.json").read_text() == "[1]"


def test_weather_hourly_keeps_the_longer_span(tmp_path):
    lake = Lake(tmp_path / "lake")
    old = pd.DataFrame({"ts": pd.date_range("2026-08-01", periods=48, freq="h"), "temp_c": 20.0})
    (lake.root / "context").mkdir()
    old.to_csv(lake.root / "context" / "weather_hourly.csv.gz", index=False, compression="gzip")
    import gzip
    new = pd.DataFrame({"ts": pd.date_range("2026-08-02 12:00", periods=48, freq="h"), "temp_c": 21.0})
    lake._ingest_context("weather_hourly.csv.gz", gzip.compress(new.to_csv(index=False).encode()))
    merged = pd.read_csv(lake.root / "context" / "weather_hourly.csv.gz")
    assert len(merged) == 84 and merged["temp_c"].iloc[-1] == 21.0 and merged["temp_c"].iloc[0] == 20.0


def test_normalize_types():
    df = pd.DataFrame({"trip_key": ["a"], "trip_id": ["t"], "route_id": ["6"], "start_date": [20260901], "direction": ["N"], "stop_id": ["631N"],
                       "arrival_ts": ["1790000000"], "sched_track": [np.nan], "actual_track": [4.0], "confidence": [0.9]})
    out = lk._normalize("arrivals", df)
    assert list(out.columns) == lk.ARRIVAL_COLUMNS
    assert out["start_date"].iloc[0] == "20260901" and out["actual_track"].iloc[0] == "4" and pd.isna(out["sched_track"].iloc[0])
    assert out["arrival_ts"].dtype == "float64" and out["arrival_ts"].iloc[0] == 1790000000.0 and pd.isna(out["n_predictions"].iloc[0])
