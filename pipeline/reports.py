"""Keep the riders' reports: pull the trip relay's recent list into the data branch (reports/reports.jsonl).

    python -m pipeline.reports --data-dir data-branch      # WHICHWAY_RELAY=https://..., WHICHWAY_REPORTS_READ_KEY optional

The relay keeps two days; the hourly pipeline keeps everything. With the read key the list carries each report's
stable reporter hash, which the reporter weights need (mta_delay_insights.analysis.rider_reports); without it the
day's hash stands in. No relay address: nothing to do.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import time
import urllib.request
from pathlib import Path

from mta_delay_insights.analysis.rider_reports import load_reports, merge_reports

from . import lib

PATH = Path("reports") / "reports.jsonl"


def fetch(relay: str, since: float, read_key: str | None = None, timeout: float = 30) -> list[dict]:
    req = urllib.request.Request(f"{relay.rstrip('/')}/v1/reports?since={int(since)}", headers={"user-agent": "whichway-pipeline"})
    if read_key:
        req.add_header("x-whichway-read-key", read_key)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = json.loads(r.read().decode())
    return body.get("reports") or []


def main(argv=None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--data-dir", default=str(lib.DEFAULT_DATA_DIR))
    ap.add_argument("--relay", default=os.environ.get("WHICHWAY_RELAY", ""))
    args = ap.parse_args(argv)
    if not args.relay.startswith("https://"):
        logging.info("no relay address (WHICHWAY_RELAY): rider reports skipped")
        return 0
    path = Path(args.data_dir) / PATH
    have = load_reports(path)
    since = max(float(have["ts"].max()) - 3600, time.time() - 2 * 86400) if len(have) else time.time() - 2 * 86400
    try:
        new = fetch(args.relay, since, os.environ.get("WHICHWAY_REPORTS_READ_KEY") or None)
    except Exception as exc:
        logging.warning("rider reports unavailable: %s", exc)
        return 0
    n = merge_reports(path, new)
    logging.info("rider reports: %d listed, %d new, %d kept", len(new), n, len(have) + n)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
