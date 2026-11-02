# The modelling engine runs on the Mac

_Written 2026-10-31. The gatherers on the web keep collecting; this Mac keeps everything they collect, develops the
models on it, and publishes what the site and the app run. This note is the design, what of it exists now, and
what comes next._

## Where things stand

| piece | runs | sees | produces | reaches the app how |
|---|---|---|---|---|
| hourly GitHub Action (`pipeline.yml`) | the web, unattended, every hour (166 collect runs so far) | the 8 NYCT feeds for 50 min of each hour at every stop; the subwaydata.nyc archive for the last 21 days; Open Data, weather, alerts | the `data` branch: day files of arrivals, ETA samples, dwells, holds, forecast scores, alerts, context; then the site build | the site build fits `client_model.json` (feed-ETA calibration on ≤45 days, lateness-carry tables on the **last 200 000 arrivals, about one day**, hold survival on 30 days) and publishes it to GitHub Pages; the app fetches it |
| subwaydata.nyc archive | the web | every train at every stop since April 2021, train ids and tracks, 1.4 MB a day | one file per service day | only through the Action's 21-day window |
| the trip relay (Cloudflare Worker) | the web | each phone's finished trips and traces | files in the private `whichway-data` repo | the trip review on the Mac |
| this Mac's server (`com.whichway.serve`) | while the Mac is awake; continuous since Oct 5 | every poll of every feed every 30 s, alerts with real last-seen times, goodservice samples, its own forecast scores | `data/mta.sqlite`, 2.5 GB and growing, no archive of it | `make model` (the learned arrival model, 45 min, server-side only), `make delay-model` (`delay_model.json`, reaches the app by being force-added to the code repo), the trip review, the stop corpus |

What this caps:

- **Three weeks of history.** The branch prunes the network arrivals to 21 days, so every retrain sees three weeks
  (`docs/model_report.md`: weather, alerts and events "added nothing measurable on a dry 3-week span", and the
  report's own first next step was to let the span grow). The archive has a year and more.
- **The app's engine is fitted on days.** The carry tables that the phone applies to every train come from one day
  of arrivals; the per-band tables need 150 pairs to exist at all and mostly fall back to the route.
- **No road from the Mac to the phone.** The only Mac-trained model the app runs is the delay model, committed into
  the code repository by hand. The learned arrival model never leaves the server.
- **The store is the only copy of the Mac's own record**, growing 15–80 MB a day, with the gaps of a laptop (Sep
  28 – Oct 4 is missing) and no way to prune it without losing the alert lifetimes and holds it alone has.

## The shape of it

```
   gather (web, unattended)              hand off (nightly)          develop (this Mac)              publish                 serve
   ────────────────────────              ───────────────────         ──────────────────              ───────                 ─────
   GitHub Action ─► data branch ──┐                                  make model-lake ──► card        make bundle             the app
   subwaydata.nyc archive ────────┼──► make lake ──► data/lake/ ──►  make delay-model ─► json  ──►  make bundle-publish ──► the site
   trip relay ─► whichway-data ───┤        (Parquet, DuckDB)         trip review, corpus            (models branch) ──┐      the server
   this Mac's server ─► store ────┘                                  experiments                                       └─► Action installs
                                                                                                                           it into the site
```

Three rules hold it together:

1. **Gathering never depends on the Mac.** The Action, the archive and the relay run whether the laptop is open or
   not. The Mac's server is a richer gatherer when it is on (every 30 s, every stop, the alert ends), never the
   only one.
2. **The lake only grows.** Everything the gatherers produce is pulled into `data/lake/` before any rolling window
   drops it; the branch, the store and the Action's build directories become caches.
3. **The Mac publishes, the Action installs.** Models fitted here go out as a bundle on a `models` branch; the
   hourly site build verifies it and copies it over its own fit when it is fresh; the app reads the same URLs it
   always did. Nothing trip-derived can enter the bundle.

## 1. Gathering stays on the web

The Action, the archive and the relay are kept as they are. One addition is worth considering once the lake has
shown what the archive cannot give:

**The Worker as a feed recorder (phase 2).** A Cron Trigger every minute fetches the 8 feeds and writes the raw
protobuf to R2 (`raw/<feed>/<day>/<hhmmss>.pb`); the Mac pulls each day and replays it (`mta-insights replay`
already rebuilds arrivals, ETA samples and dwells from raw snapshots). On the free plan: 8 × 1 440 = 11 520 writes
a day, about 350 000 a month against the 1 000 000 allowed; ~150 KB a feed is ~1.7 GB a day, so the 10 GB free
bucket holds under a week and needs a lifecycle rule of a few days with a nightly pull (egress is free), or the
$5 plan. What it buys: every minute of every feed, with no 10-minute hole in each hour and no dependence on the
laptop, which is what the **ETA samples, dwells and holds at every stop** need (the Action keeps those for the
monitored platforms only). What it does not buy: arrivals, which the archive already has in full.

## 2. The hand-off: the lake (built)

`data/lake/` (gitignored like all of `data/`) is a directory of Parquet partitions, one per table, local day and
source, that `make lake` keeps in step with the gatherers. `mta_delay_insights/lake.py` is the library,
`pipeline/lake.py` the command.

```
arrivals/day=2026-10-30/source=archive/rows.parquet     subwaydata.nyc (via the branch, or fetched here)
arrivals/day=2026-10-30/source=action/rows.parquet      the Action's collector rows
arrivals/day=2026-10-30/source=mac/rows.parquet         this Mac's store
eta_samples/ dwells/ holds/ segment_runs/ forecast_eval/ snapshots/   the same shape (action, mac)
alerts/<day>.json.gz  alerts/mac.parquet                the branch's day files; the store's alerts (real ends)
context/*.csv.gz  context/goodservice.parquet           the branch's context tables; the store's community samples
manifest.json  sync_log.json                            what was ingested, so a sync only does new work
```

- **From the branch:** read straight from the repository's git objects (`git cat-file`), so no worktree has to be
  kept current; a blob already in the manifest is skipped. Context tables are copied byte for byte so
  `pipeline.lib.load_context` and the alert loader work on the lake unchanged (the weather-hourly cache is merged,
  keeping the longer span).
- **From the archive:** the service days the lake lacks, newest first, `LAKE_FETCH` (30) a night at 1.4 MB each, back
  to `LAKE_DAYS` (365). A day the archive has not published yet is retried every night while young and monthly
  once old. A service day counts as had when its own local day holds the bulk of it and the next day its
  after-midnight spill, so the branch's day files and direct fetches agree.
- **From the store:** read-only, by local day; a day is re-exported when its row count changed, so the open store
  is never written and the running server is never disturbed. The forecast scores accumulate (the store keeps a
  rolling 50 000); the alerts and goodservice samples are whole tables.
- **One convention per day.** Archive rows mark an arrival ~40 s later than the feed-dropped rows; the training
  loader takes the archive when it has the day (> 50 000 rows) and the collectors otherwise, exactly as
  `pipeline.train_model` always decided, and the serving-condition check uses the collector rows alone.
- **Every partition write merges** (union, dedupe on the table's keys), so the branch, a fetched service day and a
  store export can each add to the same day.

Commands:

```bash
make lake                                  # one sync (the branch, up to 30 archive days, the store); nightly: make lake-nightly
make lake-status                           # coverage by table, source and day; the gaps; archive days still unpublished
make lake-sql Q="select day, source, count(*) n from arrivals group by 1,2 order by 1"     # DuckDB over the Parquet
```

Measured on the first sync (2026-10-31, `--archive-days 120 --max-fetch 40`): the branch's 298 files in under a
minute, 40 archive days and the store's 32 days, 408 MB of Parquet. Arrivals cover 61 days (2026-09-01 .. 2026-10-31),
60 of them with the archive: 12.5 M archive rows, 5.7 M from the store, 0.3 M from the Action; 5.6 M ETA samples,
5.2 M dwells, 127 k holds, 424 k segment runs. A weekday's archive holds about 230 k arrivals, a weekend day about
145 k. The 57 days still wanted (July and August) arrive over the next two nights at `LAKE_FETCH=30`.

That first sync took 1 h 44 min, 2.5 minutes an archive day, and almost none of it was work: the archive's day files
redirect to a CDN host with IPv6 addresses this network cannot reach, and `requests` waited out two connect
timeouts per day before falling back to IPv4 (curl's happy eyeballs hides the same thing in 0.4 s). The fetcher now
gives each address a short connect timeout and, once a host's IPv6 proves dead, stays on IPv4 for the process
(`mta_delay_insights/net.py`): the next three days took 18 s, 1.4 s and 1.3 s, so a night's 30 days are a minute.

The trips are not in the lake. They stay in `data/trips/` and the private repository, and the lake has nothing
the public branch did not already have.

## 3. Developing on the Mac: the workbench

The hardware is not the constraint: an M5 Max with 18 CPU cores, 64 GB and 1.2 TB free. The constraints were the
three-week window and the ad hoc paths, which the lake and the bundle remove.

**Training from the lake.** `make model-lake` runs `pipeline/train_model.py --lake data/lake` (the same rows,
features, hold-out and reports as `make model`, now over every day the lake has) into `data/models_lake/` with a
rows cache. `scripts/model_compare.py` scores an older model on the newer run's held-out rows, which is the only
fair comparison between two runs.

**Scale.** A year of the archive is ~84 M arrivals, ~100 M training rows at the 30 % trip sample. The current fit
(scikit-learn histogram boosting, 255 leaves, 1 500 rounds) took 35 min on 6 M rows, so a year wants one of:
a lower per-day sample for the span and the full sample for the last months; LightGBM (a wheel exists for this
Python; it needs Homebrew's `libomp`) which is several times faster on this many cores and converts to Core ML;
building the stream features in DuckDB instead of pandas. PyTorch's MPS backend is there for sequence models over a
line's state if trees plateau.

**The row build runs one process per day.** Each archive day is single-threaded pandas (230 k arrivals become 2.1 M
rows before the 30 % sample), so `train_model.py` builds the days in worker processes: `--jobs N` (`JOBS=N` for
`make model-lake`), by default one per day up to the CPU count and 6 GB of memory a worker (10 workers for 10 days
on this Mac, 11 for 60); `--jobs 1` is the old serial loop. The rows are the same either way: the days land in day
order and the sample keeps whole trips by a hash of the trip key, so `rows.pkl` comes out byte for byte the same.
Measured on 2026-10-31 over 2026-10-20..29 with `make model-lake`'s flags:

| row build, 10 archive days | wall time | per day | peak memory |
|---|---|---|---|
| serial (`--jobs 1`) | 13 min 15 s | 67–90 s | 6.0 GB, one process |
| 10 workers (default) | 2 min 16 s | 91–116 s | 2.9 GB a worker, 4.0 GB the parent |

`rows.pkl` is 2.2 GB for the ten days (about 220 MB a day at the 30 % sample), and the parent holds every day's
kept rows until the cache is written. Sixty days should take about 11 minutes instead of 80 (estimated from this
run, not measured).

The first run through the lake path, three days (2026-10-27..29, the last held out) at 50 rounds and a 10 % sample,
ended at an MAE of 78.7 s against the schedule's 88.1 s with the p10–p90 range covering 80 %, and 78.1 s on that
day's collector rows (the feed's own ETAs: 81.5 s); 14 minutes end to end, 7 of them the fit. The same path with
`make model-lake` runs over every day the lake has.

**What months of history can answer that three weeks could not.** Rain, snow, heat and wind effects; the
holiday weeks; alert causes over hundreds of alerts rather than dozens; day patterns by season; the rider's own
legs over hundreds of rides instead of 115–400 rows; whether goodservice.io's reroute flags add anything (sampled
since Oct 5, back-testable once the lake holds the same weeks).

**Candidate models**, each with what it needs and where it runs:

| model | question it answers | data | runs on |
|---|---|---|---|
| arrival model on months (exists; longer span) | when does this train reach stop *k* ahead, with a range | lake arrivals + context | server; its card and segment profiles to the app |
| client tables on months (bundle today) | the feed's error by route × horizon (× band), carry per route × band with real counts, hold survival by line | lake arrivals, ETA samples, holds | the phone and the browser |
| segment profiles by band (next) | what this segment usually does at this hour on this kind of day | the arrival model's out-of-fold profiles | a small table in the bundle; the planner's "typical loss" |
| gap / practical-lateness model | how long until the next train really comes, given the line's state | lake arrivals (headways), alerts | the planner's wait; the server's status |
| hold and incident hazard | how much longer this hold lasts; will this alert clear in 15 / 30 / 60 min | the store's dwells and alert ends, months of them | extends `delay_model.json` |
| door-to-door from the rider's trips | where the end-to-end forecast loses time around the model | `data/trips/` (private) | the Mac only; aggregate corrections go in the bundle |
| station-stop sensing | which station the train stopped at, from motion | the stop corpus (`make corpus`) | Core ML on the phone, replacing the quiet rule |
| on-device arrival model | the learned model's forecast without a server | the lake; features the phone can compute from the feeds | Core ML (LightGBM / XGBoost convert; scikit-learn's histogram trees do not) |

**Discipline.** Every run writes its `experiments.json` and card to its own folder (never straight into `data/`),
holds out time-ordered days, reports the schedule, carry and feed baselines beside the model, checks the
collector rows separately, and gets a dated entry in `docs/model_report.md`. A model is only "better" on the
same held-out rows as the one it replaces.

## 4. Publishing: the model bundle (built)

`make bundle` (`pipeline/bundle.py build`) writes `data/bundle/`:

| file | from | note |
|---|---|---|
| `client_model.json` | fitted here from the lake: ETA calibration and carry tables on 45 days (1.5 M arrivals in whole trips, against one day before), hold survival from the branch's holds and the Mac's dwells | the same schema the phone and the browser already read; `fitted_on` says what it saw |
| `delay_model.json` | `data/delay_model.json` from `make delay-model` | — |
| `arrival.card.json` | `data/arrival.card.json` from `make model` / `make model-lake` | the rider's leg tables stripped |
| `model_manifest.json` | — | version, build time, the lake's span, a summary per model, a SHA-256 per file |

`pipeline.bundle check` refuses any file carrying a `legs`, `rider`, `install_id` or `trips` key or such text; `build`
runs it and will not write a bundle that fails. `make bundle-publish` commits the bundle to the `models` branch in
its own worktree (`models-branch/`, gitignored) and pushes it, the way the Action keeps the `data` branch. The hourly
pipeline now has a step after the site build that checks the branch out, verifies the digests and, when the bundle
is under 30 days old, copies its files over the build's own (`_site/data/client_model.json`, `delay_model.json`,
`models/arrival.card.json`, plus the manifest); a stale bundle leaves the build's fresher fit in place. The app
fetches the same file names from the same base URL, so it takes the Mac's model with no change; `make ios-seed`
bakes the published copy into the app as before.

The first bundle (2026-10-31) took 18 minutes to build and passed the check: the client tables saw 45 days
(2026-09-17 .. 2026-10-31), 4.8 M ETA samples over 21 routes, 644 k holds, and carry pairs from 1.5 M arrivals over
29 routes, where the Action's hourly fit sees the last 200 k rows. It was published to the `models` branch the same
afternoon (commit `da6cd4d`); `publish` now refuses to commit when git has no identity configured, since that first
commit went out signed as the user at this machine's hostname. The site's `client_model.json` of the same
morning carries an empty carry table (`lateness_carry.n` = 0, no routes), so the phone and the browser have been
running without one; the bundle is the first with the table filled. It sits in `data/bundle/` and on the branch; the hourly build installs it once the install step is on the branch the Action runs from.

Later: `model_manifest.json` in the app's Settings data status ("engine fitted on 45 days to Oct 30"); a Core ML
model in the bundle once there is one; the Worker and an R2 bucket as a model CDN if bundles outgrow a git branch.

## 5. Phases

**Phase 0 (this change).** The lake and its sync, status and SQL commands; the nightly agent; training from the
lake; the bundle with its privacy check, publish and install; tests for all of it (`tests/test_lake.py`,
`tests/test_bundle.py`); the pipeline's install step.

**Phase 1 (next).** Install the nightly agent and let the archive fill back a year (about two weeks at 30 days a
night; `LAKE_FETCH=120 make lake` hurries it). Publish the first bundle and confirm on the site's Model page and
the app's data status that it was installed. Retrain on 60–90 days and compare to the Oct 8 model on the same
held-out rows; rerun the feature ablation on a span with rain. Add the segment profiles by band to the bundle and
the Swift predictor (with its fixture).

**Phase 2.** The Worker as a feed recorder if full-resolution ETA samples and holds are wanted; prune the SQLite
store once the lake has each month; LightGBM for the long-span fits and a first Core ML arrival model.

**Phase 3.** The gap model, the hold hazard on months of ends, the rider's door-to-door corrections, station-stop
sensing from the corpus.

## Commands

```bash
make lake LAKE_DAYS=365 LAKE_FETCH=30     # sync; make lake-nightly installs the 03:20 agent (scripts/lake_agent.sh remove)
make lake-status                          # what is there
make lake-sql Q="..."                     # ask it
make model-lake END=2026-10-30 TEST_FROM=2026-10-24     # train on the lake into data/models_lake
make delay-model                          # the delay model from the store (as before)
make bundle                               # data/bundle from the lake and this Mac's models; refuses trip-derived content
make bundle-publish                       # push to the models branch (a public branch: on the owner's say-so)
.venv/bin/python -m pipeline.bundle install --bundle models-branch --site _site/data   # what the Action runs
```
