"""Build the station-stop training corpus from the rider's trips (ultra training mode stops, else the motion traces)
and the trains the trip review matched: data/corpus/station_stops.csv, summary.json and summary.md (git-ignored:
the corpus holds the rider's movements). Runs the trip review first; `make trips` before it pulls the newest trips."""
from __future__ import annotations

import argparse
import json
import sqlite3
from pathlib import Path

from mta_delay_insights import corpus, trips
from mta_delay_insights.storage.db import Store
from pipeline import lib


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="data/mta.sqlite")
    ap.add_argument("--gtfs", default="data/gtfs_subway.zip")
    ap.add_argument("--trips", default="data/trips")
    ap.add_argument("--out", default="data/corpus")
    args = ap.parse_args()
    static = lib.load_static(args.gtfs)
    # the review first, with this code: the legs' trains and which of the phone's rides each one is (a running server
    # reviews on its own schedule with the code it started with)
    trips.review_all(Store(args.db), static, Path(args.trips))
    con = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    out = Path(args.out)
    df = corpus.build(out, con, static, Path(args.trips))
    s = corpus.summarize(df)
    (out / "summary.json").write_text(json.dumps(s, indent=1))
    (out / "summary.md").write_text(corpus.render(s))
    print(corpus.render(s))
    print(f"{len(df)} rows -> {out / 'station_stops.csv'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
