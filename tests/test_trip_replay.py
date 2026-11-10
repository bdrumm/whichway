"""pipeline.trip_replay: the fixtures it writes for the Swift replay, on synthetic trips and trains only."""
import json

from pipeline import trip_replay as rp

SCHED = {"lines": {
    "F_N": {"stops": ["F20N", "F21N", "A41N", "A40N"]},
    "A_N": {"stops": ["A42N", "A41N", "A40N", "A38N"]},
    "G_N": {"stops": ["F22N", "F20N", "A42N"]},
    "L_E": {"stops": ["L01E", "L02E"]},
}}


def test_route_stations_takes_every_stop_ridden_on_each_leg():
    legs = [{"line": "F_N", "from": "F20N", "to": "A41N"}, {"line": "A_N", "from": "A41N", "to": "A38N"}]
    assert rp.route_stations(SCHED, legs) == {"F20", "F21", "A41", "A40", "A38"}


def test_route_stations_falls_back_to_the_ends_when_the_line_does_not_run_that_way():
    assert rp.route_stations(SCHED, [{"line": "F_N", "from": "A41N", "to": "F20N"}]) == {"A41", "F20"}


def test_routes_at_lists_every_route_calling_at_the_stations():
    assert rp.routes_at(SCHED, {"F20"}) == {"F", "G"}
    assert rp.routes_at(SCHED, {"A41"}) == {"F", "A"}
    assert rp.routes_at(SCHED, {"X99"}) == set()


def test_truth_for_keeps_the_review_legs_and_flags():
    review = {"riderLines": ["F", "C"], "missedChange": True, "falseStart": False,
              "legs": [{"leg": 0, "riderRoute": "F", "train": {"trip_id": "t1", "route": "F"}, "matchedBy": "phone", "plan": "F_N"}]}
    t = rp.truth_for(review)
    assert t["riderLines"] == ["F", "C"] and t["missedChange"] is True
    assert t["legs"][0] == {"leg": 0, "riderRoute": "F", "riderTransfer": None, "train": "t1", "route": "F", "matchedBy": "phone", "plan": "F_N"}
    assert rp.truth_for(None) == {}


def test_export_writes_a_fixture_only_for_trips_with_a_trace(tmp_path, monkeypatch):
    trips = [{"id": "a", "createdTs": 1000.0, "endedTs": 2000.0, "legs": [{"line": "F_N", "from": "F20N", "to": "A41N"}], "events": []},
             {"id": "b", "createdTs": 5000.0, "endedTs": 6000.0, "legs": [{"line": "F_N", "from": "F20N", "to": "A41N"}]},
             {"id": "c", "createdTs": 9000.0, "legs": []}]
    traces = {1002.0: {"columns": ["ts", "stepEnergy", "pushG", "shakeG"], "seconds": [[1002.0, 0.0, 0.0, 0.0]], "startTs": 1002.0},
              9000.0: {"columns": ["ts"], "seconds": [], "startTs": 9000.0}}
    monkeypatch.setattr(rp.tr, "collect_observations", lambda store, d: trips)
    monkeypatch.setattr(rp.tr, "load_traces", lambda d: traces if d.name == "github" else {})
    out = rp.export(None, tmp_path / "trips", SCHED, tmp_path / "out")
    assert [p.name for p in out] == ["1000.json"]
    fx = json.loads(out[0].read_text())
    assert fx["trip"]["id"] == "a" and fx["trace"]["startTs"] == 1002.0
    assert fx["arrivals"] == [] and fx["dwells"] == [] and fx["truth"] == {}
