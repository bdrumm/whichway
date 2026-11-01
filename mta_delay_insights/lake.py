"""The lake: every record the gatherers produce, kept on this Mac for as long as we want it.

The gatherers run unattended on the web and keep rolling windows: the hourly GitHub Action writes the day's
arrivals, ETA samples, dwells, holds and alerts to the ``data`` branch and prunes the network-wide arrivals to
three weeks; the subwaydata.nyc archive publishes one file per service day; this Mac's own server polls every
30 seconds into ``data/mta.sqlite`` while the Mac is awake. None of them is the record. The lake is: a
directory of Parquet partitions (one per table, day and source) that only grows, so the modelling work on this
Mac can train on months instead of the three weeks the branch keeps, and the SQLite store can be pruned.

Layout (``data/lake/``, gitignored like everything under ``data/``)::

    arrivals/day=2026-10-30/source=archive/rows.parquet     subwaydata.nyc, via the branch or fetched here
    arrivals/day=2026-10-30/source=action/rows.parquet      the Action's own collector rows (feed convention)
    arrivals/day=2026-10-30/source=mac/rows.parquet         this Mac's store
    eta_samples/ dwells/ holds/ segment_runs/ forecast_eval/ snapshots/   the same shape
    alerts/2026-10-30.json.gz                               the branch's day files, byte for byte
    alerts/mac.parquet                                      the store's alerts (real last-seen times)
    context/<name>.csv.gz                                   the branch's context tables (weather, events, ...)
    context/goodservice.parquet                             the store's community-status samples
    manifest.json                                           what was ingested, so a sync only does new work

Three sources, one convention each: ``archive`` rows mark an arrival when the archive marked the stop past
(~40 s after the feed drops it), ``action`` and ``mac`` rows when the feed dropped it. The training loader
keeps one convention per day (the archive when it has the day), as ``pipeline.train_model`` always did.

Writes to a partition merge: a day file from the branch, a service day fetched from the archive and a store
export can each add rows to the same local day, so every write unions with what is there and dedupes on the
table's keys. Partitions are small (a day of one source), so that costs nothing.
"""
from __future__ import annotations

import gzip
import io
import json
import logging
import sqlite3
import subprocess
import time
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Callable

import numpy as np
import pandas as pd

from .sources import subwaydata
from .sources.gtfs_static import NY_TZ
from .storage.db import ARRIVAL_COLUMNS, DWELL_COLUMNS, ETA_SAMPLE_COLUMNS

log = logging.getLogger("lake")

VERSION = 1
ARCHIVE, ACTION, MAC = "archive", "action", "mac"
SOURCES = (ARCHIVE, ACTION, MAC)
ARCHIVE_FULL_DAY = 50_000            # archive rows that make a day "the archive's" for training (one convention per day)
SERVICE_DAY_FULL = 100_000           # rows of a service day in its own local day before the service day counts as had
SERVICE_DAY_SPILL = 1_000            # rows of a service day in the next local day (its trips past midnight)
HOLD_SEC = 150.0
SNAPSHOT_COLUMNS = ["feed", "fetched_at", "feed_ts", "n_trip_updates", "n_vehicles", "n_arrivals_emitted"]
SEGMENT_RUN_COLUMNS = ["trip_key", "route_id", "direction", "from_stop", "to_stop", "depart_ts", "arrive_ts", "run_sec"]
FORECAST_EVAL_COLUMNS = ["made_ts", "target_id", "stop_id", "trip_id", "route_id", "horizon_sec", "feed_eta_ts", "model_eta_ts", "model_source",
                         "sim_eta_ts", "hold_eta_ts", "corroboration", "holding", "stalled", "stops_away", "arrival_ts", "feed_err_sec",
                         "model_err_sec", "sim_err_sec"]

# table -> (columns, timestamp column that places a row on a local day, keys a partition dedupes on, string columns)
TABLES: dict[str, tuple[list[str], str, list[str], set[str]]] = {
    "arrivals": (ARRIVAL_COLUMNS, "arrival_ts", ["trip_key", "stop_id"],
                 {"trip_key", "trip_id", "route_id", "start_date", "direction", "stop_id", "source", "train_id", "sched_track", "actual_track"}),
    "eta_samples": (ETA_SAMPLE_COLUMNS, "at_ts", ["trip_key", "stop_id", "at_stop"], {"trip_key", "route_id", "stop_id", "at_stop"}),
    "dwells": (DWELL_COLUMNS, "stopped_from_ts", ["trip_key", "stop_id"], {"trip_key", "route_id", "direction", "stop_id"}),
    "holds": (DWELL_COLUMNS, "stopped_from_ts", ["trip_key", "stop_id"], {"trip_key", "route_id", "direction", "stop_id"}),
    "segment_runs": (SEGMENT_RUN_COLUMNS, "depart_ts", ["trip_key", "from_stop", "to_stop"], {"trip_key", "route_id", "direction", "from_stop", "to_stop"}),
    "forecast_eval": (FORECAST_EVAL_COLUMNS, "made_ts", ["made_ts", "trip_id", "stop_id"], {"target_id", "stop_id", "trip_id", "route_id", "model_source", "corroboration"}),
    "snapshots": (SNAPSHOT_COLUMNS, "fetched_at", ["feed", "fetched_at"], {"feed"}),
}
# the branch's day-file folders and the lake table each lands in
BRANCH_DAY_DIRS = {"arrivals_all": "arrivals", "arrivals": "arrivals", "eta_samples": "eta_samples", "dwells": "dwells", "holds": "holds",
                   "segment_runs": "segment_runs", "forecast_eval": "forecast_eval"}
# the store's tables exported by day
STORE_DAY_TABLES = {"arrivals": "arrivals", "eta_samples": "eta_samples", "dwells": "dwells", "snapshots": "snapshots"}
RETRY_YOUNG_DAYS = 7                 # an archive day this young that 404'd is tried again at every sync (the archive lags)
RETRY_OLD_SEC = 30 * 86400           # an older day that 404'd is tried again after a month


def local_day(ts: float) -> date:
    return datetime.fromtimestamp(float(ts), NY_TZ).date()


def day_bounds(day: date) -> tuple[float, float]:
    start = datetime(day.year, day.month, day.day, tzinfo=NY_TZ).timestamp()
    return start, datetime.combine(day + timedelta(days=1), datetime.min.time(), NY_TZ).timestamp()


def _normalize(table: str, df: pd.DataFrame) -> pd.DataFrame:
    """The table's columns in order, strings as strings and numbers as floats, so partitions always merge."""
    cols, _, _, strings = TABLES[table]
    out = df.reindex(columns=cols).copy()
    for c in cols:
        if c in strings:
            s = out[c]
            if pd.api.types.is_numeric_dtype(s.dtype):
                # integers read from a CSV or a NULL column (a start_date, a track number) are the strings the feed had
                s = s.map(lambda v: None if v is None or (isinstance(v, float) and not np.isfinite(v)) else (str(int(v)) if float(v) == int(v) else str(v)))
            out[c] = s.astype(object).where(s.notna(), None).astype("string")
        else:
            out[c] = pd.to_numeric(out[c], errors="coerce").astype("float64")
    return out


def _read_parquet(p: Path) -> pd.DataFrame:
    return pd.read_parquet(p)


def _rows_in(p: Path) -> int:
    try:
        import pyarrow.parquet as pq
        return int(pq.read_metadata(p).num_rows)
    except Exception:
        return int(len(pd.read_parquet(p)))


class GitTree:
    """Read a branch's files straight from the repository's objects (no worktree to keep up to date)."""

    def __init__(self, repo: str | Path, ref: str):
        self.repo = str(repo)
        self.ref = ref

    def _git(self, *args: str) -> bytes:
        return subprocess.run(["git", "-C", self.repo, *args], check=True, capture_output=True).stdout

    def fetch(self, remote: str = "origin", branch: str | None = None) -> None:
        branch = branch or self.ref.split("/", 1)[-1]
        subprocess.run(["git", "-C", self.repo, "fetch", "-q", remote, branch], check=True, capture_output=True)

    def files(self) -> dict[str, tuple[str, int]]:
        """path -> (blob id, size) for every file on the ref."""
        out: dict[str, tuple[str, int]] = {}
        for line in self._git("ls-tree", "-r", "-l", self.ref).decode().splitlines():
            meta, path = line.split("\t", 1)
            parts = meta.split()
            if len(parts) >= 4 and parts[1] == "blob":
                out[path] = (parts[2], int(parts[3]))
        return out

    def read(self, blob: str) -> bytes:
        return self._git("cat-file", "blob", blob)


class DirTree:
    """The same interface over a directory laid out like the branch (a worktree, or a test fixture)."""

    def __init__(self, root: str | Path):
        self.root = Path(root)

    def fetch(self, *a, **k) -> None:
        return None

    def files(self) -> dict[str, tuple[str, int]]:
        out = {}
        for p in sorted(self.root.rglob("*")):
            if p.is_file() and ".git" not in p.parts:
                st = p.stat()
                rel = p.relative_to(self.root).as_posix()
                out[rel] = (f"{rel}:{st.st_size}:{int(st.st_mtime)}", st.st_size)
        return out

    def read(self, blob: str) -> bytes:
        return (self.root / blob.split(":", 1)[0]).read_bytes()


class Lake:
    def __init__(self, root: str | Path = "data/lake"):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self._manifest_path = self.root / "manifest.json"
        self.manifest: dict = json.loads(self._manifest_path.read_text()) if self._manifest_path.exists() else {}
        self.manifest.setdefault("version", VERSION)
        self.manifest.setdefault("branch", {})           # branch path -> blob ingested
        self.manifest.setdefault("archive", {})          # service day -> {"rows"} or {"error", "at"}
        self.manifest.setdefault("service_days", {})     # local day -> {service day: rows} in its archive partition
        self.manifest.setdefault("store", {})            # table -> day -> rows exported

    def save_manifest(self) -> None:
        self.manifest["saved_at"] = datetime.now(NY_TZ).isoformat()
        self._manifest_path.write_text(json.dumps(self.manifest, indent=1, sort_keys=True))

    # ------------------------------------------------------------------ partitions
    def partition(self, table: str, day: date | str, source: str) -> Path:
        d = day if isinstance(day, str) else day.isoformat()
        return self.root / table / f"day={d}" / f"source={source}" / "rows.parquet"

    def write(self, table: str, day: date | str, source: str, df: pd.DataFrame, merge: bool = True) -> int:
        """Rows of one table, local day and source; merged with the partition's rows unless ``merge`` is off."""
        if df is None or df.empty:
            return 0
        _, _, keys, _ = TABLES[table]
        new = _normalize(table, df)
        p = self.partition(table, day, source)
        if merge and p.exists():
            old = _read_parquet(p)
            new = pd.concat([old, new], ignore_index=True)
        new = new.drop_duplicates(keys, keep="last").reset_index(drop=True)
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_suffix(".tmp.parquet")
        new.to_parquet(tmp, index=False)
        tmp.replace(p)
        return int(len(new))

    def write_days(self, table: str, source: str, df: pd.DataFrame, merge: bool = True) -> dict[str, int]:
        """Rows of one table split by local day."""
        if df is None or df.empty:
            return {}
        _, ts_col, _, _ = TABLES[table]
        ts = pd.to_numeric(df[ts_col], errors="coerce")
        df = df[ts.notna()]
        if df.empty:
            return {}
        days = ts[ts.notna()].map(local_day)
        out = {}
        for d, g in df.groupby(days.values):
            out[d.isoformat()] = self.write(table, d, source, g, merge=merge)
        return out

    def days(self, table: str, source: str | None = None) -> list[date]:
        d = self.root / table
        if not d.exists():
            return []
        out = set()
        for p in d.glob("day=*"):
            if source is None or (p / f"source={source}" / "rows.parquet").exists():
                if any(p.glob("source=*/rows.parquet")):
                    out.add(date.fromisoformat(p.name[4:]))
        return sorted(out)

    def read(self, table: str, day: date | str, source: str) -> pd.DataFrame | None:
        p = self.partition(table, day, source)
        return _read_parquet(p) if p.exists() else None

    def read_range(self, table: str, start: date | None = None, end: date | None = None, sources: tuple[str, ...] = SOURCES) -> pd.DataFrame:
        """Every partition of the table between two local days (inclusive), deduped on the table's keys."""
        _, _, keys, _ = TABLES[table]
        frames = []
        for d in self.days(table):
            if (start and d < start) or (end and d > end):
                continue
            for s in sources:
                f = self.read(table, d, s)
                if f is not None and len(f):
                    frames.append(f)
        if not frames:
            return pd.DataFrame(columns=TABLES[table][0])
        return pd.concat(frames, ignore_index=True).drop_duplicates(keys, keep="first").reset_index(drop=True)

    # ------------------------------------------------------------------ what the trainer reads
    def arrivals(self, day: date, prefer_archive: bool = True) -> pd.DataFrame:
        """The day's arrivals in one convention: the archive's when it has the day, else the collectors' (Mac first)."""
        if prefer_archive:
            a = self.read("arrivals", day, ARCHIVE)
            if a is not None and len(a) > ARCHIVE_FULL_DAY:
                return a.drop_duplicates(["trip_key", "stop_id"], keep="first").reset_index(drop=True)
        frames = [f for f in (self.read("arrivals", day, MAC), self.read("arrivals", day, ACTION)) if f is not None and len(f)]
        if not frames:
            return pd.DataFrame(columns=ARRIVAL_COLUMNS)
        return pd.concat(frames, ignore_index=True).drop_duplicates(["trip_key", "stop_id"], keep="first").reset_index(drop=True)

    def arrival_source(self, day: date) -> str:
        a = self.partition("arrivals", day, ARCHIVE)
        if a.exists() and _rows_in(a) > ARCHIVE_FULL_DAY:
            return ARCHIVE
        return "collector" if any(self.partition("arrivals", day, s).exists() for s in (MAC, ACTION)) else "none"

    def eta_samples(self, start: date | None = None, end: date | None = None) -> pd.DataFrame:
        return self.read_range("eta_samples", start, end, (MAC, ACTION))

    def dwells(self, start: date | None = None, end: date | None = None) -> pd.DataFrame:
        return self.read_range("dwells", start, end, (MAC, ACTION))

    def holds(self, start: date | None = None, end: date | None = None, hold_sec: float = HOLD_SEC) -> pd.DataFrame:
        """Stops of ``hold_sec`` or longer: the branch's hold log and the Mac's dwells above the threshold."""
        h = self.read_range("holds", start, end, (ACTION,))
        d = self.dwells(start, end)
        if len(d):
            d = d[d["dwell_sec"] >= hold_sec]
        frames = [f for f in (h, d) if len(f)]
        if not frames:
            return pd.DataFrame(columns=DWELL_COLUMNS)
        return pd.concat(frames, ignore_index=True).drop_duplicates(["trip_key", "stop_id"], keep="first").reset_index(drop=True)

    def alerts(self) -> pd.DataFrame:
        """The branch's daily alert files and the store's alerts, one row per (alert, activation), latest last-seen wins."""
        cols = ["alert_id", "alert_type", "planned", "cause_category", "created_at", "updated_at", "active_start", "active_end",
                "routes", "stops", "header", "description", "last_seen_ts"]
        rows: list[dict] = []
        d = self.root / "alerts"
        for f in sorted(d.glob("*.json.gz")) if d.exists() else []:
            with gzip.open(f, "rt") as fh:
                rows.extend(json.load(fh))
        frames = []
        if rows:
            frames.append(pd.DataFrame(rows))
        mac = d / "mac.parquet"
        if mac.exists():
            m = _read_parquet(mac)
            for c in ("routes", "stops"):
                m[c] = m[c].map(lambda s: json.loads(s) if isinstance(s, str) and s.startswith("[") else [])
            frames.append(m)
        if not frames:
            return pd.DataFrame(columns=cols)
        df = pd.concat(frames, ignore_index=True).reindex(columns=cols)
        df["planned"] = df["planned"].fillna(False).astype(bool)
        df["last_seen_ts"] = pd.to_numeric(df["last_seen_ts"], errors="coerce")
        df = df.sort_values("last_seen_ts", na_position="first").drop_duplicates(["alert_id", "active_start"], keep="last")
        return df.reset_index(drop=True)

    # ------------------------------------------------------------------ sync: the branch
    def sync_tree(self, tree, fetch: bool = True) -> dict:
        """Ingest every new or changed file of a data-branch tree; unchanged blobs are skipped."""
        if fetch:
            try:
                tree.fetch()
            except Exception as exc:
                log.warning("fetch failed (%s); using what is there", exc)
        files = tree.files()
        seen = self.manifest["branch"]
        report = {"files": 0, "rows": 0, "skipped": 0, "tables": {}}
        for path in sorted(files):
            blob, size = files[path]
            if seen.get(path) == blob:
                report["skipped"] += 1
                continue
            top = path.split("/", 1)[0]
            name = path.rsplit("/", 1)[-1]
            try:
                if top in BRANCH_DAY_DIRS and name.endswith(".csv.gz") and name[:4].isdigit():
                    n = self._ingest_branch_day(BRANCH_DAY_DIRS[top], top, name[:10], tree.read(blob))
                    report["rows"] += n
                    report["tables"][BRANCH_DAY_DIRS[top]] = report["tables"].get(BRANCH_DAY_DIRS[top], 0) + 1
                elif top == "alerts" and name.endswith(".json.gz"):
                    dst = self.root / "alerts" / name
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    dst.write_bytes(tree.read(blob))
                    report["tables"]["alerts"] = report["tables"].get("alerts", 0) + 1
                elif top == "context" and name.endswith(".csv.gz"):
                    self._ingest_context(name, tree.read(blob))
                    report["tables"]["context"] = report["tables"].get("context", 0) + 1
                elif path in ("runs.json", "arrivals_all/backfill_manifest.json"):
                    dst = self.root / "branch" / path
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    dst.write_bytes(tree.read(blob))
                else:
                    continue
            except Exception as exc:
                log.warning("%s not ingested: %s", path, exc)
                continue
            seen[path] = blob
            report["files"] += 1
        self.save_manifest()
        return report

    def _ingest_branch_day(self, table: str, top: str, day: str, data: bytes) -> int:
        strings = TABLES[table][3]
        df = pd.read_csv(io.BytesIO(data), compression="gzip", low_memory=False, dtype={c: str for c in strings})
        n = 0
        if table == "arrivals":
            src = df["source"].astype(str) if "source" in df else pd.Series("", index=df.index)
            arch = df[src == subwaydata.SOURCE]
            if len(arch):
                n += self.write("arrivals", day, ARCHIVE, arch)
                self._note_service_days(day, arch)
            rest = df[src != subwaydata.SOURCE]
            if len(rest):
                n += self.write("arrivals", day, ACTION, rest)
        else:
            n += self.write(table, day, ACTION, df)
        return n

    def _note_service_days(self, day: str, arch: pd.DataFrame) -> None:
        counts = arch["start_date"].astype(str).str.replace("-", "").value_counts()
        rec = self.manifest["service_days"].setdefault(day, {})
        for sd, n in counts.items():
            if len(sd) == 8 and sd.isdigit():
                key = f"{sd[:4]}-{sd[4:6]}-{sd[6:]}"
                rec[key] = max(int(n), int(rec.get(key, 0)))

    def _ingest_context(self, name: str, data: bytes) -> None:
        dst = self.root / "context" / name
        dst.parent.mkdir(parents=True, exist_ok=True)
        if name == "weather_hourly.csv.gz" and dst.exists():
            # the trainer extends this cache back to the first training day; keep the longer span
            old = pd.read_csv(dst)
            new = pd.read_csv(io.BytesIO(data), compression="gzip")
            if len(old) and "ts" in old and "ts" in new:
                both = pd.concat([old, new], ignore_index=True)
                both["ts"] = pd.to_datetime(both["ts"])
                both = both.drop_duplicates("ts", keep="last").sort_values("ts")
                both.to_csv(dst, index=False, compression="gzip")
                return
        dst.write_bytes(data)

    # ------------------------------------------------------------------ sync: the archive
    def service_day_covered(self, sd: date) -> bool:
        """A service day is in the lake when its own local day holds the bulk of it and the next day its spill-over."""
        own = self.manifest["service_days"].get(sd.isoformat(), {}).get(sd.isoformat(), 0)
        spill = self.manifest["service_days"].get((sd + timedelta(days=1)).isoformat(), {}).get(sd.isoformat(), 0)
        return own >= SERVICE_DAY_FULL and spill >= SERVICE_DAY_SPILL

    def archive_wanted(self, days_back: int, today: date | None = None, now: float | None = None) -> list[date]:
        """Service days in the window not yet in the lake, newest first, honouring the retry rules for failed fetches."""
        today = today or datetime.now(NY_TZ).date()
        now = now or time.time()
        out = []
        for i in range(1, days_back + 1):
            sd = today - timedelta(days=i)
            if self.service_day_covered(sd):
                continue
            rec = self.manifest["archive"].get(sd.isoformat())
            if rec and rec.get("error"):
                age_days = (today - sd).days
                if age_days > RETRY_YOUNG_DAYS and now - float(rec.get("at", 0)) < RETRY_OLD_SEC:
                    continue
            out.append(sd)
        return out

    def sync_archive(self, days_back: int, max_fetch: int = 30, fetch: Callable[[date], pd.DataFrame] | None = None,
                     pause_sec: float = 0.5, today: date | None = None) -> dict:
        """Fetch the service days the lake lacks from subwaydata.nyc (``fetch`` returns a day's arrivals frame)."""
        fetch = fetch or (lambda d: subwaydata.backfill_days([d])[d])
        wanted = self.archive_wanted(days_back, today)[:max_fetch]
        report = {"wanted": len(self.archive_wanted(days_back, today)), "fetched": [], "failed": {}}
        for sd in wanted:
            t0 = time.time()
            df = fetch(sd)
            if df is None or df.empty:
                err = (df.attrs.get("error") if df is not None else None) or "empty"
                self.manifest["archive"][sd.isoformat()] = {"error": str(err)[:120], "at": time.time()}
                report["failed"][sd.isoformat()] = str(err)[:120]
                log.info("archive %s: %s", sd, err)
            else:
                written = self.write_days("arrivals", ARCHIVE, df)
                for d, g in df.groupby(pd.to_numeric(df["arrival_ts"], errors="coerce").map(local_day).values):
                    self._note_service_days(d.isoformat(), g)
                self.manifest["archive"][sd.isoformat()] = {"rows": int(len(df)), "at": time.time(), "days": written}
                report["fetched"].append({"day": sd.isoformat(), "rows": int(len(df)), "seconds": round(time.time() - t0, 1)})
                log.info("archive %s: %d arrivals in %.0fs", sd, len(df), time.time() - t0)
            self.save_manifest()
            if pause_sec:
                time.sleep(pause_sec)
        return report

    # ------------------------------------------------------------------ sync: the Mac's store
    def sync_store(self, db: str | Path, today: date | None = None) -> dict:
        """Export the store's tables by local day; a day is re-exported when its row count changed."""
        db = Path(db)
        if not db.exists():
            return {"error": f"no store at {db}"}
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        report = {"tables": {}}
        try:
            for src_table, table in STORE_DAY_TABLES.items():
                ts_col = TABLES[table][1]
                try:
                    hourly = pd.read_sql(f"SELECT CAST({ts_col}/3600 AS INTEGER) AS h, COUNT(*) AS n FROM {src_table} WHERE {ts_col} IS NOT NULL GROUP BY h", con)
                except Exception as exc:
                    report["tables"][table] = {"error": str(exc)[:120]}
                    continue
                if hourly.empty:
                    continue
                per_day: dict[str, int] = {}
                for h, n in zip(hourly["h"].astype(int), hourly["n"].astype(int)):
                    per_day[local_day(h * 3600).isoformat()] = per_day.get(local_day(h * 3600).isoformat(), 0) + n
                have = self.manifest["store"].setdefault(table, {})
                exported = {}
                for d in sorted(per_day):
                    if have.get(d, {}).get("rows") == per_day[d]:
                        continue
                    lo, hi = day_bounds(date.fromisoformat(d))
                    df = pd.read_sql(f"SELECT * FROM {src_table} WHERE {ts_col} >= ? AND {ts_col} < ?", con, params=(lo, hi))
                    n = self.write(table, d, MAC, df, merge=False)
                    have[d] = {"rows": per_day[d], "at": time.time()}
                    exported[d] = n
                report["tables"][table] = {"days": len(exported), "rows": int(sum(exported.values()))}
            # the forecast scores: a rolling frame in the store, accumulated here
            try:
                fe = pd.read_sql("SELECT * FROM ctx_forecast_eval", con)
                if len(fe):
                    w = self.write_days("forecast_eval", MAC, fe)
                    report["tables"]["forecast_eval"] = {"days": len(w), "rows": int(sum(w.values()))}
            except Exception:
                pass
            # alerts with their real last-seen times, and the community status samples: whole tables, small
            try:
                al = pd.read_sql("SELECT * FROM alerts", con)
                if len(al):
                    p = self.root / "alerts" / "mac.parquet"
                    p.parent.mkdir(parents=True, exist_ok=True)
                    al.to_parquet(p, index=False)
                    report["tables"]["alerts"] = {"rows": int(len(al))}
            except Exception as exc:
                report["tables"]["alerts"] = {"error": str(exc)[:120]}
            try:
                gs = pd.read_sql("SELECT * FROM ctx_goodservice", con)
                if len(gs):
                    p = self.root / "context" / "goodservice.parquet"
                    p.parent.mkdir(parents=True, exist_ok=True)
                    gs.to_parquet(p, index=False)
                    report["tables"]["goodservice"] = {"rows": int(len(gs))}
            except Exception:
                pass
        finally:
            con.close()
        self.save_manifest()
        return report

    # ------------------------------------------------------------------ what is there
    def coverage(self) -> dict:
        """Per table and source: days, span and rows (from the Parquet footers, so this is cheap)."""
        out: dict = {"tables": {}, "arrival_days": {}}
        for table in TABLES:
            d = self.root / table
            if not d.exists():
                continue
            per_source: dict[str, dict] = {}
            for p in sorted(d.glob("day=*/source=*/rows.parquet")):
                day = p.parent.parent.name[4:]
                src = p.parent.name[7:]
                n = _rows_in(p)
                s = per_source.setdefault(src, {"days": 0, "rows": 0, "first": day, "last": day})
                s["days"] += 1; s["rows"] += n; s["first"] = min(s["first"], day); s["last"] = max(s["last"], day)
                if table == "arrivals":
                    out["arrival_days"].setdefault(day, {})[src] = n
            if per_source:
                out["tables"][table] = per_source
        days = sorted(out["arrival_days"])
        if days:
            first, last = date.fromisoformat(days[0]), date.fromisoformat(days[-1])
            span = [(first + timedelta(days=i)).isoformat() for i in range((last - first).days + 1)]
            out["arrival_gaps"] = [d for d in span if d not in out["arrival_days"]]
            out["archive_days"] = sum(1 for d in days if out["arrival_days"][d].get(ARCHIVE, 0) > ARCHIVE_FULL_DAY)
            out["span"] = {"first": days[0], "last": days[-1], "days": len(span)}
        al = self.root / "alerts"
        out["alert_files"] = len(list(al.glob("*.json.gz"))) if al.exists() else 0
        ctx = self.root / "context"
        out["context"] = sorted(p.name for p in ctx.iterdir()) if ctx.exists() else []
        out["archive_failed"] = sorted(k for k, v in self.manifest["archive"].items() if v.get("error"))
        return out

    def status_text(self, days: int = 14) -> str:
        cov = self.coverage()
        lines = [f"lake {self.root} ({self.manifest.get('saved_at', 'never synced')})"]
        if not cov["tables"]:
            lines.append("  empty: run `make lake`")
            return "\n".join(lines)
        lines.append(f"  {'table':<14}{'source':<9}{'days':>6}{'rows':>12}  span")
        for table, srcs in cov["tables"].items():
            for src, s in srcs.items():
                lines.append(f"  {table:<14}{src:<9}{s['days']:>6}{s['rows']:>12,}  {s['first']} .. {s['last']}")
        if cov.get("span"):
            sp = cov["span"]
            lines.append(f"  arrivals: {sp['days']} days {sp['first']} .. {sp['last']}, {cov['archive_days']} with the archive, "
                         f"{len(cov['arrival_gaps'])} without any source" + (f" ({', '.join(cov['arrival_gaps'][:6])}{'...' if len(cov['arrival_gaps']) > 6 else ''})" if cov["arrival_gaps"] else ""))
        if cov["archive_failed"]:
            lines.append(f"  archive days not published yet or failed: {', '.join(cov['archive_failed'][-6:])}")
        lines.append(f"  alerts: {cov['alert_files']} day files" + (" + the store's" if (self.root / 'alerts' / 'mac.parquet').exists() else "") + f"; context: {len(cov['context'])} tables")
        recent = sorted(cov["arrival_days"])[-days:]
        if recent:
            lines.append(f"  {'day':<12}{'archive':>9}{'action':>9}{'mac':>9}   training convention")
            for d in recent:
                r = cov["arrival_days"][d]
                lines.append(f"  {d:<12}{r.get(ARCHIVE, 0):>9,}{r.get(ACTION, 0):>9,}{r.get(MAC, 0):>9,}   {self.arrival_source(date.fromisoformat(d))}")
        return "\n".join(lines)

    # ------------------------------------------------------------------ queries
    def connect(self):
        """A DuckDB connection with a view per table over the Parquet partitions (``day`` and ``source`` columns)."""
        import duckdb
        con = duckdb.connect()
        for table in TABLES:
            d = self.root / table
            if d.exists() and any(d.glob("day=*/source=*/rows.parquet")):
                glob = (d / "day=*" / "source=*" / "rows.parquet").as_posix()
                con.execute(f"CREATE VIEW {table} AS SELECT * FROM read_parquet('{glob}', hive_partitioning=true, union_by_name=true)")
        return con

    def sql(self, query: str) -> pd.DataFrame:
        con = self.connect()
        try:
            return con.execute(query).df()
        finally:
            con.close()

    # ------------------------------------------------------------------ one sync
    def sync(self, tree=None, db: str | Path | None = None, archive_days: int = 0, max_fetch: int = 30, fetch=None, fetch_tree: bool = True,
             today: date | None = None) -> dict:
        t0 = time.time()
        report: dict = {"at": datetime.now(NY_TZ).isoformat()}
        if tree is not None:
            report["branch"] = self.sync_tree(tree, fetch=fetch_tree)
        if archive_days > 0:
            report["archive"] = self.sync_archive(archive_days, max_fetch=max_fetch, fetch=fetch, today=today)
        if db is not None:
            report["store"] = self.sync_store(db, today=today)
        report["seconds"] = round(time.time() - t0, 1)
        logp = self.root / "sync_log.json"
        hist = json.loads(logp.read_text()) if logp.exists() else []
        hist.append(report)
        logp.write_text(json.dumps(hist[-200:], indent=0, default=str))
        return report
