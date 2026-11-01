"""The model bundle: what this Mac publishes for the site and the app to use.

    python -m pipeline.bundle build   --lake data/lake --out data/bundle [--days 45] [--carry-rows 1500000]
    python -m pipeline.bundle check   --bundle data/bundle
    python -m pipeline.bundle publish --bundle data/bundle [--branch models] [--no-push]
    python -m pipeline.bundle install --bundle models-branch --site _site/data [--max-age-days 30]

``build`` fits the client prediction engine's tables (``client_model.json``: feed ETA calibration, hold survival,
lateness carry) from the lake instead of the branch's rolling window, takes the delay-alert model and the
arrival model's card from this Mac's ``data/``, and writes ``model_manifest.json`` with a version, what the
models were fitted on and a digest of every file. ``check`` refuses anything trip-derived: the rider's legs,
install ids, trip records never leave this Mac (the card's ``legs`` tables are stripped by ``build``).
``publish`` commits the bundle to the ``models`` branch, the way the Action keeps the ``data`` branch, and
pushes it. ``install`` is what the hourly site build runs: it verifies the digests and, when the bundle is
fresh enough, copies its files over the ones the build fitted itself, so the published site and the app
(which reads the same URLs) run on the Mac's models.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import logging
import shutil
import subprocess
import sys
import time
from datetime import date, datetime, timedelta
from pathlib import Path

import pandas as pd

from mta_delay_insights.lake import ACTION, ARCHIVE, MAC, Lake
from mta_delay_insights.realtime import client_model as cm
from mta_delay_insights.sources.gtfs_static import NY_TZ

from . import lib

log = logging.getLogger("bundle")

MODEL_FILES = ("client_model.json", "delay_model.json", "arrival.card.json")
MANIFEST = "model_manifest.json"
# a key or a text that marks something trip-derived; none may be in a published file
PRIVATE_KEYS = {"legs", "legs_collector", "rider", "rider_notes", "install_id", "installid", "trips", "observations", "traces"}
PRIVATE_TEXT = ("rider", "installId", "install_id")


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def strip_private(obj):
    """The same JSON without the keys that carry the rider's own data."""
    if isinstance(obj, dict):
        return {k: strip_private(v) for k, v in obj.items() if str(k).lower() not in PRIVATE_KEYS}
    if isinstance(obj, list):
        return [strip_private(v) for v in obj]
    return obj


def private_findings(bundle: Path) -> list[str]:
    """Where a bundle still carries trip-derived content (empty when it is fit to publish)."""
    out = []
    for p in sorted(bundle.glob("*.json")):
        try:
            obj = json.loads(p.read_text())
        except Exception as exc:
            out.append(f"{p.name}: unreadable ({exc})")
            continue

        def walk(o, path):
            if isinstance(o, dict):
                for k, v in o.items():
                    if str(k).lower() in PRIVATE_KEYS:
                        out.append(f"{p.name}: key {path}/{k}")
                    walk(v, f"{path}/{k}")
            elif isinstance(o, list):
                for i, v in enumerate(o[:50]):
                    walk(v, f"{path}[{i}]")
            elif isinstance(o, str) and any(t in o for t in PRIVATE_TEXT):
                out.append(f"{p.name}: text at {path}")
        walk(obj, "")
    for p in bundle.iterdir():
        if p.is_file() and p.suffix not in (".json", ".md"):
            out.append(f"{p.name}: not a JSON table")
    return out


def _sample_trips(df: pd.DataFrame, cap: int, seed: int = 1) -> pd.DataFrame:
    """At most ``cap`` rows, whole trips kept together (the carry tables need consecutive stops of a trip)."""
    if len(df) <= cap:
        return df
    share = cap / len(df)
    h = pd.util.hash_pandas_object(df["trip_key"], index=False).values % 10_000
    return df[h < int(share * 10_000)]


def build(lake: Lake, static, out: Path, days: int = 45, carry_rows: int = 1_500_000, now: datetime | None = None,
          delay_model: Path = Path("data/delay_model.json"), arrival_card: Path = Path("data/arrival.card.json")) -> dict:
    now = now or datetime.now(NY_TZ)
    out.mkdir(parents=True, exist_ok=True)
    for p in out.glob("*"):
        if p.is_file():
            p.unlink()
    lake_days = lake.days("arrivals")
    if not lake_days:
        raise SystemExit(f"the lake at {lake.root} has no arrivals: run `make lake` first")
    last = lake_days[-1]
    start = last - timedelta(days=days - 1)
    t0 = time.time()
    # the feed's convention for the ETA calibration (collector rows first), the archive's bulk for the carry tables
    coll = lake.read_range("arrivals", start, last, (MAC, ACTION))
    arch = lake.read_range("arrivals", start, last, (ARCHIVE,))
    arrivals = pd.concat([f for f in (coll, arch) if len(f)], ignore_index=True).drop_duplicates(["trip_key", "stop_id"], keep="first") \
        if len(coll) or len(arch) else coll
    eta = lake.eta_samples(start, last)
    holds = lake.holds(start, last)
    log.info("bundle span %s..%s: %d arrivals (%d collector, %d archive), %d eta samples, %d holds, loaded in %.0fs",
             start, last, len(arrivals), len(coll), len(arch), len(eta), len(holds), time.time() - t0)
    t0 = time.time()
    carry_arr = _sample_trips(arrivals, carry_rows)
    client = {"version": cm.VERSION, "generated_at": now.isoformat(), "eta_calibration": cm.fit_eta_calibration(eta, arrivals),
              "hold_survival": cm.fit_hold_survival(holds, static), "lateness_carry": cm.fit_lateness_carry(carry_arr, static, max_rows=carry_rows),
              "constants": {"min_headway_sec": cm.MIN_HEADWAY_SEC, "min_stop_gap_sec": cm.MIN_STOP_GAP_SEC, "hold_sec": cm.HOLD_SEC, "max_k": cm.MAX_K},
              "fitted_on": {"first_day": start.isoformat(), "last_day": last.isoformat(), "arrivals": int(len(arrivals)), "carry_arrivals": int(len(carry_arr)),
                            "eta_samples": int(len(eta)), "holds": int(len(holds)), "source": "lake"}}
    (out / "client_model.json").write_text(json.dumps(client, default=str))
    log.info("client model fitted in %.0fs: eta n=%d routes=%d, holds=%d, carry n=%d routes=%d", time.time() - t0, client["eta_calibration"]["n"],
             len(client["eta_calibration"]["by_route"]), client["hold_survival"]["n_holds"], client["lateness_carry"]["n"], len(client["lateness_carry"]["by_route"]))
    summary: dict = {"client_model": {"generated_at": client["generated_at"], "eta_samples": client["eta_calibration"]["n"],
                                      "routes_calibrated": len(client["eta_calibration"]["by_route"]), "holds": client["hold_survival"]["n_holds"],
                                      "carry_pairs": client["lateness_carry"]["n"], "routes_carry": len(client["lateness_carry"]["by_route"]),
                                      "fitted_on": client["fitted_on"]}}
    if delay_model.exists():
        dm = json.loads(delay_model.read_text())
        (out / "delay_model.json").write_text(json.dumps(strip_private(dm), default=str))
        summary["delay_model"] = {k: dm.get(k) for k in ("generated", "generated_at", "n_alerts", "version") if k in dm}
    if arrival_card.exists():
        card = strip_private(json.loads(arrival_card.read_text()))
        (out / "arrival.card.json").write_text(json.dumps(card, default=str))
        ev = card.get("evaluation") or {}
        summary["arrival_model"] = {"status": card.get("status"), "trained_at": card.get("trained_at"), "n_train": card.get("n_train"),
                                    "mae_model": ev.get("mae_model"), "mae_schedule": ev.get("mae_schedule"), "coverage_p10_p90": ev.get("coverage_p10_p90")}
    cov = lake.coverage()
    manifest = {"version": now.strftime("%Y%m%dT%H%M%SZ") if now.tzinfo is None else now.astimezone(NY_TZ).strftime("%Y%m%d-%H%M"),
                "built_at": now.isoformat(), "built_ts": now.timestamp(), "lake": {"span": cov.get("span"), "archive_days": cov.get("archive_days")},
                "models": summary, "files": {}}
    for p in sorted(out.glob("*.json")):
        if p.name != MANIFEST:
            manifest["files"][p.name] = {"sha256": sha256(p), "bytes": p.stat().st_size}
    (out / MANIFEST).write_text(json.dumps(manifest, indent=1, default=str))
    bad = private_findings(out)
    if bad:
        for b in bad:
            log.error("private content: %s", b)
        raise SystemExit("the bundle carries trip-derived content; not written for publishing")
    (out / "README.md").write_text("# models\n\nThe model bundle built on the Mac by `make bundle` (`pipeline/bundle.py`): the client prediction engine's\n"
                                   "tables fitted from the lake, the delay-alert model and the arrival model's card. The hourly site build installs\n"
                                   "it over its own fit when it is fresh; the app reads the same files from the published site.\n")
    return manifest


def verify(bundle: Path) -> dict:
    m = json.loads((bundle / MANIFEST).read_text())
    for name, meta in m.get("files", {}).items():
        p = bundle / name
        if not p.exists():
            raise SystemExit(f"{name} listed in the manifest is missing")
        if sha256(p) != meta["sha256"]:
            raise SystemExit(f"{name} does not match its digest")
    return m


def install(bundle: Path, site_data: Path, max_age_days: float = 30, now: float | None = None) -> dict:
    """Copy a fresh, verified bundle over the site build's own tables (what the Action runs after the build)."""
    now = now or time.time()
    if not (bundle / MANIFEST).exists():
        return {"installed": False, "reason": "no manifest"}
    m = verify(bundle)
    age_days = (now - float(m.get("built_ts", 0))) / 86400
    bad = private_findings(bundle)
    if bad:
        return {"installed": False, "reason": "private content", "findings": bad}
    if age_days > max_age_days:
        log.warning("bundle %s is %.0f days old (limit %.0f): the build's own tables stay", m.get("version"), age_days, max_age_days)
        return {"installed": False, "reason": "stale", "age_days": round(age_days, 1), "version": m.get("version")}
    site_data.mkdir(parents=True, exist_ok=True)
    copied = []
    for name in m["files"]:
        src = bundle / name
        dst = site_data / "models" / name if name == "arrival.card.json" else site_data / name
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)
        copied.append(dst.as_posix())
    shutil.copyfile(bundle / MANIFEST, site_data / MANIFEST)
    log.info("installed bundle %s (%.1f days old): %s", m.get("version"), age_days, ", ".join(m["files"]))
    return {"installed": True, "version": m.get("version"), "age_days": round(age_days, 1), "files": copied}


def _git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(repo), *args], check=check, capture_output=True, text=True)


def publish(bundle: Path, repo: Path = lib.ROOT, remote: str = "origin", branch: str = "models", worktree: str = "models-branch", push: bool = True) -> dict:
    """Commit the bundle to the models branch in its own worktree and push it."""
    m = verify(bundle)
    bad = private_findings(bundle)
    if bad:
        raise SystemExit("private content in the bundle: " + "; ".join(bad))
    ident = _git(repo, "config", "user.email", check=False).stdout.strip()
    if not ident:       # git would sign a public commit as <user>@<this machine's hostname>; the first publish did (2026-10-31)
        raise SystemExit("no git identity: set `git config --global user.email` (and user.name) before publishing to a public branch")
    repo = Path(repo).resolve()
    wt = repo / worktree
    remote_has = _git(repo, "ls-remote", "--exit-code", "--heads", remote, branch, check=False).returncode == 0
    if not (wt / ".git").exists():
        if remote_has:
            _git(repo, "fetch", "-q", remote, branch)
            _git(repo, "worktree", "add", str(wt), f"{remote}/{branch}")
            _git(wt, "checkout", "-q", "-B", branch)
        else:
            r = _git(repo, "worktree", "add", "--orphan", "-b", branch, str(wt), check=False)
            if r.returncode != 0:       # older git: detach, then orphan
                _git(repo, "worktree", "add", "--detach", str(wt))
                _git(wt, "checkout", "-q", "--orphan", branch)
                _git(wt, "rm", "-rfq", "--cached", ".", check=False)
    elif remote_has:
        _git(repo, "fetch", "-q", remote, branch)
        _git(wt, "checkout", "-q", "-B", branch, f"{remote}/{branch}")
    for p in wt.iterdir():
        if p.name == ".git":
            continue
        shutil.rmtree(p) if p.is_dir() else p.unlink()
    for p in bundle.iterdir():
        if p.is_file():
            shutil.copyfile(p, wt / p.name)
    _git(wt, "add", "-A")
    if _git(wt, "diff", "--cached", "--quiet", check=False).returncode == 0:
        return {"committed": False, "reason": "unchanged", "version": m.get("version")}
    span = (m.get("lake") or {}).get("span") or {}
    _git(wt, "commit", "-q", "-m", f"models: {m.get('version')} (lake {span.get('first')}..{span.get('last')})")
    sha = _git(wt, "rev-parse", "--short", "HEAD").stdout.strip()
    out = {"committed": True, "version": m.get("version"), "commit": sha, "pushed": False}
    if push:
        _git(wt, "push", "-q", remote, f"HEAD:{branch}")
        out["pushed"] = True
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--lake", default="data/lake")
    b.add_argument("--out", default="data/bundle")
    b.add_argument("--gtfs", default="data/gtfs_subway.zip")
    b.add_argument("--days", type=int, default=45, help="days of the lake the client tables are fitted on")
    b.add_argument("--carry-rows", type=int, default=1_500_000, help="arrivals the lateness-carry tables are fitted on (whole trips)")
    b.add_argument("--delay-model", default="data/delay_model.json")
    b.add_argument("--arrival-card", default="data/arrival.card.json")
    c = sub.add_parser("check")
    c.add_argument("--bundle", default="data/bundle")
    p = sub.add_parser("publish")
    p.add_argument("--bundle", default="data/bundle")
    p.add_argument("--repo", default=str(lib.ROOT))
    p.add_argument("--remote", default="origin")
    p.add_argument("--branch", default="models")
    p.add_argument("--no-push", action="store_true")
    i = sub.add_parser("install")
    i.add_argument("--bundle", required=True)
    i.add_argument("--site", required=True, help="the built site's data directory (_site/data)")
    i.add_argument("--max-age-days", type=float, default=30)
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", stream=sys.stderr)
    if args.cmd == "build":
        static = lib.load_static(args.gtfs)
        m = build(Lake(args.lake), static, Path(args.out), days=args.days, carry_rows=args.carry_rows,
                  delay_model=Path(args.delay_model), arrival_card=Path(args.arrival_card))
        print(json.dumps({k: m[k] for k in ("version", "built_at", "lake", "models")}, indent=1, default=str))
        return 0
    if args.cmd == "check":
        bad = private_findings(Path(args.bundle))
        print("\n".join(bad) if bad else "clean")
        return 1 if bad else 0
    if args.cmd == "publish":
        print(json.dumps(publish(Path(args.bundle), Path(args.repo), args.remote, args.branch, push=not args.no_push), indent=1))
        return 0
    if args.cmd == "install":
        print(json.dumps(install(Path(args.bundle), Path(args.site), args.max_age_days), indent=1))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
