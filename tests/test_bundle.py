"""The model bundle: built from the lake, free of the rider's data, installed by the site build, published to a branch."""
from __future__ import annotations

import json
import subprocess
from datetime import datetime, timedelta
from pathlib import Path

import pytest

pytest.importorskip("pyarrow")

from mta_delay_insights.sources.gtfs_static import NY_TZ  # noqa: E402
from pipeline import bundle as bd  # noqa: E402
from tests.test_lake import make_lake  # noqa: E402


def _build(static, tmp_path, monkeypatch, when: datetime | None = None):
    lake, sim, _, _, days, _ = make_lake(static, tmp_path, monkeypatch)
    card = {"status": "ok", "trained_at": "2026-10-08", "n_train": 10, "evaluation": {"mae_model": 60.0, "mae_schedule": 80.0, "coverage_p10_p90": 0.8},
            "legs": [{"from": "A", "to": "B", "from_name": "the rider's stop"}], "legs_collector": [], "data": {"k_set": [1, 2]}}
    (tmp_path / "card.json").write_text(json.dumps(card))
    (tmp_path / "delay.json").write_text(json.dumps({"generated": "2026-10-12", "lifetime": {"all": [1.0, 0.5]}}))
    out = tmp_path / "bundle"
    when = when or datetime(2026, 10, 31, 12, 0, tzinfo=NY_TZ)
    m = bd.build(lake, static, out, days=10, carry_rows=50_000, now=when, delay_model=tmp_path / "delay.json", arrival_card=tmp_path / "card.json")
    return out, m, lake


def test_build_fits_the_client_tables_and_strips_the_rider(static, tmp_path, monkeypatch):
    out, m, lake = _build(static, tmp_path, monkeypatch)
    for f in ("client_model.json", "delay_model.json", "arrival.card.json", "model_manifest.json", "README.md"):
        assert (out / f).exists(), f
    client = json.loads((out / "client_model.json").read_text())
    assert client["eta_calibration"]["n"] == 600 and client["hold_survival"]["n_holds"] > 0 and client["lateness_carry"]["n"] > 0
    assert client["fitted_on"]["source"] == "lake" and client["fitted_on"]["arrivals"] > 1000
    card = json.loads((out / "arrival.card.json").read_text())
    assert "legs" not in card and "legs_collector" not in card and card["evaluation"]["mae_model"] == 60.0
    assert set(m["files"]) == {"client_model.json", "delay_model.json", "arrival.card.json"}
    assert m["models"]["arrival_model"]["mae_model"] == 60.0 and m["models"]["client_model"]["eta_samples"] == 600 and m["lake"]["archive_days"] == 3
    assert bd.private_findings(out) == [] and bd.verify(out)["version"] == m["version"]


def test_private_findings_catch_trip_derived_content(tmp_path):
    d = tmp_path / "b"; d.mkdir()
    (d / "x.json").write_text(json.dumps({"ok": 1, "nested": {"legs": [{"from": "A"}]}, "note": "from the rider"}))
    found = bd.private_findings(d)
    assert any("key /nested/legs" in f for f in found) and any("text at /note" in f for f in found)
    (d / "y.pkl").write_bytes(b"x")
    assert any("not a JSON table" in f for f in bd.private_findings(d))


def test_install_copies_a_fresh_bundle_and_skips_a_stale_one(static, tmp_path, monkeypatch):
    out, m, _ = _build(static, tmp_path, monkeypatch)
    site = tmp_path / "site" / "data"; site.mkdir(parents=True)
    (site / "client_model.json").write_text("{}")
    (out / ".git").write_text("gitdir: /somewhere/.git/worktrees/models-branch\n")     # what `git worktree add` leaves in the Action's checkout
    rep = bd.install(out, site, max_age_days=30, now=m["built_ts"] + 86400)
    assert rep["installed"] and (site / "models" / "arrival.card.json").exists() and (site / "model_manifest.json").exists()
    assert json.loads((site / "client_model.json").read_text())["fitted_on"]["source"] == "lake"
    rep = bd.install(out, site, max_age_days=30, now=m["built_ts"] + 40 * 86400)
    assert rep["installed"] is False and rep["reason"] == "stale"
    (out / "delay_model.json").write_text("{}")
    with pytest.raises(SystemExit):
        bd.install(out, site, max_age_days=30, now=m["built_ts"] + 1)


def test_publish_to_a_models_branch(static, tmp_path, monkeypatch):
    out, m, _ = _build(static, tmp_path, monkeypatch)
    bare = tmp_path / "remote.git"
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(bare)], check=True)
    work = tmp_path / "work"; work.mkdir()
    g = lambda *a: subprocess.run(["git", "-C", str(work), *a], check=True, capture_output=True, text=True)  # noqa: E731
    g("init", "-q", "-b", "main"); g("config", "user.email", "t@example.com"); g("config", "user.name", "t")
    (work / "README.md").write_text("code\n"); g("add", "-A"); g("commit", "-qm", "code"); g("remote", "add", "origin", str(bare)); g("push", "-q", "origin", "main")
    rep = bd.publish(out, repo=work, remote="origin", branch="models", worktree="models-branch", push=True)
    assert rep["committed"] and rep["pushed"] and rep["version"] == m["version"]
    names = subprocess.run(["git", "-C", str(bare), "ls-tree", "--name-only", "models"], check=True, capture_output=True, text=True).stdout.split()
    assert {"client_model.json", "model_manifest.json", "README.md"} <= set(names) and "README.md" in names
    assert "models-branch" in subprocess.run(["git", "-C", str(work), "worktree", "list"], check=True, capture_output=True, text=True).stdout
    # the same bundle again: nothing to commit; a newer one: a second commit on the branch
    assert bd.publish(out, repo=work, remote="origin", branch="models", worktree="models-branch", push=True)["committed"] is False
    (tmp_path / "again").mkdir()
    out2, m2, _ = _build(static, tmp_path / "again", monkeypatch, when=datetime(2026, 11, 1, 12, 0, tzinfo=NY_TZ))
    rep = bd.publish(out2, repo=work, remote="origin", branch="models", worktree="models-branch", push=True)
    assert rep["committed"] and rep["version"] == m2["version"]
    n = subprocess.run(["git", "-C", str(bare), "rev-list", "--count", "models"], check=True, capture_output=True, text=True).stdout.strip()
    assert n == "2"
    # the main branch is untouched
    assert subprocess.run(["git", "-C", str(bare), "ls-tree", "--name-only", "main"], check=True, capture_output=True, text=True).stdout.split() == ["README.md"]
