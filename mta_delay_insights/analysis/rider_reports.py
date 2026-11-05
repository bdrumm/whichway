"""Rider reports as feedback for the model: what riders said against what the feeds recorded.

Riders report from the app (a held train, a long wait, crowding, an incident, or that all is well); the trip relay
lists them and the pipeline keeps them (``data-branch/reports/reports.jsonl``). This module

1. **verifies** each report against the recorded network: a ``held`` report is backed when a train of that line and
   direction stood at that station two minutes or more around the report's time (the hold log), and contradicted when
   trains were recorded there then and none stood that long; a ``long_wait`` is backed by a gap of at least twice the
   line's usual headway (ten minutes at least) spanning the report; ``all_good`` is backed by neither;
2. weighs **reporters**: a Beta(1, 1) prior updated by how often the record backed them up, so one rider's word counts
   for what their history earns and no single reporter can paint the map;
3. fits the **detector thresholds** (the gap multiple and the hold length the map's live detectors use) to the riders'
   own labels, weighted by trust, per time of day. Shadow mode: the fit is published beside the thresholds in use and
   adopted only by hand once it holds up on enough labels;
4. tests reports as an **ETA feature**: whether the trust-weighted reports on a line in the last 15 minutes explain the
   MTA countdown's error there, on a time split; the feature counts only if it lowers the held-out error.

Crowding, incidents and skipped stops have no measure in the feeds: they are kept, shown and counted, never judged.
"""
from __future__ import annotations

import json
import logging
from pathlib import Path

import numpy as np
import pandas as pd

from ..sources.gtfs_static import NY_TZ

KINDS = ("held", "delay", "moving", "long_wait", "crowded", "incident", "skipped", "all_good")
UNMEASURED = {"crowded", "incident", "skipped"}
HOLD_SEC = 120.0              # a "held" report needs a stand this long
WINDOW_SEC = 600.0            # how far around a report's time the record is read
GAP_MULT, GAP_MIN_SEC = 2.5, 900.0   # the map's gap detector as it stands (site/map/engine.js)
MAP_HOLD_SEC = 150.0          # the map's hold detector (2.5 min)
MIN_LABELS = 30               # labels a time band needs before a fitted threshold is offered
BANDS = {"am_peak": (6, 10), "midday": (10, 16), "pm_peak": (16, 20), "evening": (20, 24), "night": (0, 6)}
PRESSURE_SEC = 900.0          # reports in the last 15 min make a line's report pressure


def station(stop: str) -> str:
    s = str(stop or "")
    return s[:3] if len(s) == 4 and s[-1] in "NS" else s


def base_route(r: str) -> str:
    r = str(r or "").upper()
    return r[:-1] if len(r) > 1 and r.endswith("X") else r


def band_of(ts: float) -> str:
    h = pd.Timestamp(ts, unit="s", tz="UTC").tz_convert(NY_TZ).hour
    return next(b for b, (a, z) in BANDS.items() if a <= h < z)


COLUMNS = ["id", "ts", "kind", "sub", "route", "dir", "stop", "trip", "source", "confidence", "rider", "reporter", "received_ts"]


def load_reports(path: Path) -> pd.DataFrame:
    """The kept reports (JSON lines), one row per report id, newest copy wins."""
    cols = COLUMNS
    path = Path(path)
    if not path.exists():
        return pd.DataFrame(columns=cols)
    rows = []
    for line in path.read_text().splitlines():
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if isinstance(o, dict) and o.get("kind") in KINDS and o.get("id"):
            rows.append(o)
    df = pd.DataFrame(rows)
    for c in cols:
        if c not in df:
            df[c] = None
    df = df[cols].drop_duplicates("id", keep="last")
    df["ts"] = pd.to_numeric(df["ts"], errors="coerce")
    return df.dropna(subset=["ts"]).sort_values("ts").reset_index(drop=True)


def merge_reports(path: Path, new: list[dict]) -> int:
    """Appends reports not already kept; returns how many were new."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    have = set(load_reports(path)["id"])
    fresh = []
    for r in new:
        if isinstance(r, dict) and r.get("id") and r["id"] not in have and r.get("kind") in KINDS:
            have.add(r["id"]); fresh.append(r)
    if fresh:
        with path.open("a") as f:
            for r in fresh:
                f.write(json.dumps(r, separators=(",", ":")) + "\n")
    return len(fresh)


def _prep(df: pd.DataFrame, ts_col: str) -> pd.DataFrame:
    if df is None or df.empty:
        return pd.DataFrame(columns=["route", "dir", "station", ts_col])
    out = df.copy()
    out["route"] = out["route_id"].map(base_route)
    stop = out["stop_id"].astype(str)
    sfx = stop.str[-1].where(stop.str.len() == 4)
    d = out["direction"].astype(str).str[:1].str.upper() if "direction" in out else pd.Series(None, index=out.index)
    out["dir"] = sfx.where(sfx.isin(["N", "S"]), d)
    out["station"] = stop.map(station)
    return out


def _headway(arr: pd.DataFrame) -> float | None:
    """The usual gap between trains in a slice of arrivals (the median), for want of the timetable's."""
    ts = np.sort(arr["arrival_ts"].to_numpy(dtype=float))
    g = np.diff(ts)
    g = g[(g > 30) & (g < 3600)]
    return float(np.median(g)) if len(g) >= 3 else None


def observe(r: pd.Series, arrivals: pd.DataFrame, holds: pd.DataFrame) -> dict:
    """What the record shows at the report's station, line and direction around its time."""
    def here(df, col, lo, hi):
        m = (df["route"] == base_route(r["route"])) & (df["station"] == station(r["stop"])) & (df[col] >= lo) & (df[col] <= hi)
        if r.get("dir") in ("N", "S"):
            m &= df["dir"] == r["dir"]
        return df[m]
    t = float(r["ts"])
    out: dict = {"covered": False, "hold_sec": None, "wait_sec": None, "headway_sec": None}
    a = here(arrivals, "arrival_ts", t - 3 * 3600, t + 3 * 3600)
    near = a[(a["arrival_ts"] >= t - WINDOW_SEC - 1200) & (a["arrival_ts"] <= t + WINDOW_SEC + 1200)]
    if not near.empty:
        out["covered"] = True
        before, after = a[a["arrival_ts"] <= t]["arrival_ts"], a[a["arrival_ts"] > t]["arrival_ts"]
        if len(before) and len(after):
            out["wait_sec"] = float(after.min() - before.max())
        out["headway_sec"] = _headway(a)
    h = here(holds, "stopped_from_ts", t - WINDOW_SEC - 1800, t + WINDOW_SEC) if holds is not None and not holds.empty else holds
    if h is not None and not h.empty:
        h = h[(h["stopped_to_ts"] >= t - WINDOW_SEC)]
        if not h.empty:
            out["hold_sec"] = float(h["dwell_sec"].max())
            out["covered"] = True
    return out


def verdict(kind: str, ob: dict) -> str:
    """backed | contradicted | unverified | unmeasured"""
    if kind in UNMEASURED:
        return "unmeasured"
    if not ob["covered"]:
        return "unverified"
    held = (ob["hold_sec"] or 0) >= HOLD_SEC
    hw = ob["headway_sec"]
    gap = ob["wait_sec"] is not None and ob["wait_sec"] >= max(2 * (hw or 300), 600)
    if kind == "held":
        return "backed" if held else "contradicted"
    if kind == "delay":
        return "backed" if held or gap else "contradicted"
    if kind == "long_wait":
        return "backed" if gap else ("contradicted" if ob["wait_sec"] is not None else "unverified")
    if kind == "moving":
        return "backed" if ob["hold_sec"] is not None else "unverified"
    if kind == "all_good":
        return "contradicted" if held or gap else "backed"
    return "unverified"


def verify(reports: pd.DataFrame, arrivals: pd.DataFrame, holds: pd.DataFrame) -> pd.DataFrame:
    a, h = _prep(arrivals, "arrival_ts"), _prep(holds, "stopped_from_ts")
    rows = []
    for _, r in reports.iterrows():
        ob = observe(r, a, h)
        rows.append({**r.to_dict(), **ob, "verdict": verdict(r["kind"], ob), "band": band_of(float(r["ts"]))})
    return pd.DataFrame(rows)


def reporter_trust(v: pd.DataFrame) -> pd.DataFrame:
    """Per reporter (the stable hash where the list carries it, else the day's): Beta(1 + backed, 1 + contradicted)."""
    if v.empty:
        return pd.DataFrame(columns=["who", "backed", "contradicted", "n", "trust"])
    who = v["reporter"].where(v["reporter"].notna(), v["rider"]).fillna(v["id"])
    t = v.assign(who=who).groupby("who").agg(backed=("verdict", lambda s: int((s == "backed").sum())),
                                              contradicted=("verdict", lambda s: int((s == "contradicted").sum())), n=("id", "size")).reset_index()
    t["trust"] = (1 + t["backed"]) / (2 + t["backed"] + t["contradicted"])
    return t


def _fit_threshold(x: np.ndarray, y: np.ndarray, w: np.ndarray, current: float) -> dict:
    """The cut on x that best separates rider positives (y=1) from negatives, by trust-weighted F1, against the cut
    in use. x is the measured quantity (gap over headway, hold seconds)."""
    def score(c):
        pred = x >= c
        tp, fp, fn = (w * (pred & (y == 1))).sum(), (w * (pred & (y == 0))).sum(), (w * (~pred & (y == 1))).sum()
        p = tp / (tp + fp) if tp + fp else 0.0
        rcl = tp / (tp + fn) if tp + fn else 0.0
        return float(2 * p * rcl / (p + rcl) if p + rcl else 0.0), float(p), float(rcl)
    cands = np.unique(np.concatenate([x, [current]]))
    best = max(cands, key=lambda c: (score(c)[0], -abs(c - current)))
    f_cur, p_cur, r_cur = score(current)
    f_fit, p_fit, r_fit = score(best)
    return {"current": round(float(current), 2), "fitted": round(float(best), 2), "n": int(len(x)), "positives": int(y.sum()),
            "f1_current": round(f_cur, 3), "f1_fitted": round(f_fit, 3), "precision_current": round(p_cur, 3), "precision_fitted": round(p_fit, 3),
            "recall_current": round(r_cur, 3), "recall_fitted": round(r_fit, 3)}


def detector_fit(v: pd.DataFrame, trust: pd.DataFrame) -> dict:
    """The gap and hold detectors' thresholds fitted to the riders' labels per time band (shadow mode)."""
    out = {"mode": "shadow", "min_labels": MIN_LABELS, "gap": {}, "hold": {}}
    if v.empty:
        return out
    tw = dict(zip(trust["who"], trust["trust"]))
    who = v["reporter"].where(v["reporter"].notna(), v["rider"]).fillna(v["id"])
    v = v.assign(w=who.map(tw).fillna(0.5))
    g = v[v["kind"].isin(["long_wait", "all_good"]) & v["wait_sec"].notna() & v["headway_sec"].notna()]
    hl = v[v["kind"].isin(["held", "moving", "all_good"]) & v["covered"]]
    for band in list(BANDS) + ["all"]:
        gb = g if band == "all" else g[g["band"] == band]
        if len(gb):
            res = _fit_threshold((gb["wait_sec"] / gb["headway_sec"]).to_numpy(float), (gb["kind"] == "long_wait").to_numpy(int), gb["w"].to_numpy(float), GAP_MULT)
            res["ready"] = res["n"] >= MIN_LABELS
            out["gap"][band] = res
        hb = hl if band == "all" else hl[hl["band"] == band]
        if len(hb):
            res = _fit_threshold(hb["hold_sec"].fillna(0).to_numpy(float), (hb["kind"] == "held").to_numpy(int), hb["w"].to_numpy(float), MAP_HOLD_SEC)
            res["ready"] = res["n"] >= MIN_LABELS
            out["hold"][band] = res
    return out


def report_pressure(reports: pd.DataFrame, trust: pd.DataFrame, route: np.ndarray, ts: np.ndarray) -> np.ndarray:
    """Per (route, ts): trust-weighted trouble reports on that route in the 15 minutes before, less the all-good ones."""
    out = np.zeros(len(ts))
    if reports.empty:
        return out
    tw = dict(zip(trust["who"], trust["trust"])) if not trust.empty else {}
    who = reports["reporter"].where(reports["reporter"].notna(), reports["rider"]).fillna(reports["id"])
    sign = reports["kind"].map(lambda k: 1.0 if k in ("held", "delay", "long_wait", "incident") else (-1.0 if k == "all_good" else 0.0))
    r = pd.DataFrame({"route": reports["route"].map(base_route), "ts": reports["ts"].astype(float), "w": who.map(tw).fillna(0.5) * sign})
    r = r[r["w"] != 0]
    for rt, g in r.groupby("route"):
        idx = np.where(route == rt)[0]
        if not len(idx):
            continue
        gt, gw = g["ts"].to_numpy(), g["w"].to_numpy()
        for i in idx:
            m = (gt <= ts[i]) & (gt > ts[i] - PRESSURE_SEC)
            out[i] = gw[m].sum()
    return out


def eta_feature_test(eta_samples: pd.DataFrame, arrivals: pd.DataFrame, reports: pd.DataFrame, trust: pd.DataFrame,
                     min_rows: int = 200) -> dict:
    """Does report pressure explain the MTA countdown's error? A one-term correction err ≈ b·pressure fitted on the
    earlier 70% of samples with pressure, judged by mean absolute error on the later 30%."""
    out = {"status": "insufficient", "n_with_reports": 0, "min_rows": min_rows}
    if eta_samples is None or eta_samples.empty or arrivals is None or arrivals.empty or reports.empty:
        return out
    j = eta_samples.merge(arrivals[["trip_key", "stop_id", "arrival_ts"]].drop_duplicates(["trip_key", "stop_id"]), on=["trip_key", "stop_id"])
    j["err"] = j["arrival_ts"] - j["eta_ts"]
    j = j[j["err"].abs() < 3600]
    if j.empty:
        return out
    p = report_pressure(reports, trust, j["route_id"].map(base_route).to_numpy(), j["at_ts"].to_numpy(float))
    j = j.assign(pressure=p)
    jp = j[j["pressure"] != 0].sort_values("at_ts")
    out["n_with_reports"] = int(len(jp))
    if len(jp) < min_rows:
        return out
    cut = int(len(jp) * 0.7)
    tr, te = jp.iloc[:cut], jp.iloc[cut:]
    b = float((tr["pressure"] * tr["err"]).sum() / max(1e-9, (tr["pressure"] ** 2).sum()))
    mae_base = float(te["err"].abs().mean())
    mae_feat = float((te["err"] - b * te["pressure"]).abs().mean())
    out.update({"status": "adopt" if mae_feat < mae_base * 0.98 else "reject", "sec_per_report": round(b, 1), "n_test": int(len(te)),
                "mae_without_sec": round(mae_base, 1), "mae_with_sec": round(mae_feat, 1)})
    return out


def feedback(reports: pd.DataFrame, arrivals: pd.DataFrame, holds: pd.DataFrame, eta_samples: pd.DataFrame | None, now_ts: float) -> dict:
    """Everything the System tab's "How riders train the model" shows, as one table."""
    reports = reports.reindex(columns=list(dict.fromkeys([*reports.columns, *COLUMNS])))
    out: dict = {"generated_ts": round(now_ts), "n": int(len(reports))}
    if reports.empty:
        out.update({"by_kind": {}, "verdicts": {}, "trust": {}, "detectors": detector_fit(pd.DataFrame(), pd.DataFrame()), "eta": {"status": "insufficient", "n_with_reports": 0}})
        return out
    v = verify(reports, arrivals, holds)
    t = reporter_trust(v)
    week = v[v["ts"] >= now_ts - 7 * 86400]
    out["n_week"] = int(len(week))
    out["by_kind"] = {k: int(n) for k, n in v["kind"].value_counts().items()}
    out["verdicts"] = {k: int(n) for k, n in v["verdict"].value_counts().items()}
    judged = v[v["verdict"].isin(["backed", "contradicted"])]
    out["backed_share"] = round(float((judged["verdict"] == "backed").mean()), 3) if len(judged) else None
    out["by_line"] = [{"route": r, "n": int(len(g)), "backed": int((g["verdict"] == "backed").sum()), "contradicted": int((g["verdict"] == "contradicted").sum())}
                      for r, g in v.groupby(v["route"].map(base_route))]
    out["trust"] = {"reporters": int(len(t)), "median": round(float(t["trust"].median()), 3) if len(t) else None,
                    "histogram": np.histogram(t["trust"], bins=[0, .2, .4, .6, .8, 1.0001])[0].tolist() if len(t) else []}
    out["detectors"] = detector_fit(v, t)
    try:
        out["eta"] = eta_feature_test(eta_samples, arrivals, reports, t)
    except Exception as exc:      # the table must not fail on one part
        logging.warning("rider reports: eta test failed: %s", exc)
        out["eta"] = {"status": "error"}
    out["recent"] = [{k: (None if pd.isna(x) else x) for k, x in r.items()} for r in
                     v.sort_values("ts", ascending=False).head(50)[["ts", "kind", "sub", "route", "dir", "stop", "verdict", "hold_sec", "wait_sec"]].to_dict("records")]
    return out
