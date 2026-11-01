"""Keep the local lake in step with what the gatherers collected.

    python -m pipeline.lake sync    [--lake data/lake] [--branch origin/data | --data-dir PATH] [--db data/mta.sqlite]
                                    [--archive-days 365] [--max-fetch 30] [--no-archive] [--no-store] [--no-fetch]
    python -m pipeline.lake status  [--days 14] [--json]
    python -m pipeline.lake sql "select source, count(*) from arrivals group by 1"

``sync`` reads the data branch straight from the repository's objects (fetching it first), fetches the service
days the lake still lacks from subwaydata.nyc (newest first, ``--max-fetch`` a run, so a year arrives over a
few nights), and exports this Mac's store by day. Every step is idempotent: unchanged blobs, days already in
the lake and days whose store rows have not changed are skipped.
"""
from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path

from mta_delay_insights.lake import DirTree, GitTree, Lake

from . import lib

log = logging.getLogger("lake")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--lake", default="data/lake")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sync", help="ingest the data branch, the archive and the store", parents=[common])
    s.add_argument("--branch", default="origin/data", help="the data branch ref to read (git objects, no worktree needed)")
    s.add_argument("--data-dir", default=None, help="a directory laid out like the branch, instead of --branch")
    s.add_argument("--repo", default=str(lib.ROOT))
    s.add_argument("--no-fetch", action="store_true", help="do not git-fetch the branch first")
    s.add_argument("--db", default="data/mta.sqlite", help="this Mac's store ('' to skip)")
    s.add_argument("--archive-days", type=int, default=365, help="how far back to want the subwaydata.nyc archive")
    s.add_argument("--max-fetch", type=int, default=30, help="archive days to fetch in one run (1.4 MB each; bandwidth courtesy)")
    s.add_argument("--no-archive", action="store_true")
    s.add_argument("--no-store", action="store_true")
    st = sub.add_parser("status", help="coverage by table, source and day", parents=[common])
    st.add_argument("--days", type=int, default=14)
    st.add_argument("--json", action="store_true")
    q = sub.add_parser("sql", help="run a DuckDB query over the lake's tables", parents=[common])
    q.add_argument("query")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", stream=sys.stderr)
    lake = Lake(args.lake)
    if args.cmd == "sync":
        tree = DirTree(args.data_dir) if args.data_dir else GitTree(args.repo, args.branch)
        rep = lake.sync(tree=tree, db=(args.db or None) if not args.no_store else None,
                        archive_days=0 if args.no_archive else args.archive_days, max_fetch=args.max_fetch, fetch_tree=not args.no_fetch)
        print(json.dumps(rep, indent=1, default=str))
        print(lake.status_text(days=7))
        return 0
    if args.cmd == "status":
        if args.json:
            print(json.dumps(lake.coverage(), indent=1, default=str))
        else:
            print(lake.status_text(days=args.days))
        return 0
    if args.cmd == "sql":
        import pandas as pd
        with pd.option_context("display.max_rows", 200, "display.width", 200, "display.max_columns", 40):
            print(lake.sql(args.query).to_string())
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
