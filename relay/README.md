# The trip relay

Every phone running WhichWay with "Share anonymous trip motion" on sends each finished trip (and, from developer
builds, its motion trace) to this relay, from any connection. The relay is a Cloudflare Worker on the free plan:
it checks the app key and the document, decides where the file goes, and writes it into the private data
repository (`bdrumm/whichway-data`) with a GitHub token that only the Worker holds. The repository layout is the
one the app wrote directly before (`trips/<y>/<m>/<d>/<start>-<id>.json`, `traces/trace-<start>.json`), so the
Mac's `make trips` and the local server go on pulling it every five minutes and nothing downstream changes.

Before this, a trip reached the Mac only over the home network (the local server, blocked by the firewall), by
cable (`make trips --pull`), or through the rider's own GitHub token pasted into Settings: fine for one phone,
no good for testers. The relay needs nothing on the phone but the build.

## Setting it up (once, about five minutes)

1. A Cloudflare account (free): https://dash.cloudflare.com/sign-up. Then, from `relay/`:

       npx wrangler login

   opens the browser to allow Wrangler on the account.

2. A GitHub fine-grained token for the data repository alone: github.com › Settings › Developer settings ›
   Fine-grained tokens › Generate new token; repository access *Only select repositories* → `whichway-data`;
   permissions *Contents: Read and write*. Paste it when asked:

       npx wrangler secret put GITHUB_TOKEN

3. The app key: a random string the app sends with every upload and the Worker compares. `Config/Local.xcconfig`
   already holds one as `WHICHWAY_RELAY_KEY` (made by the setup); give the Worker the same:

       sed -n 's/^WHICHWAY_RELAY_KEY *= *//p' ../ios/WhichWay/Config/Local.xcconfig | npx wrangler secret put APP_KEY

4. Deploy, and note the address it prints (`https://whichway-trips.<account>.workers.dev`):

       npx wrangler deploy          # or: make relay-deploy, from the repository root

5. Put the address in `Config/Local.xcconfig` as `WHICHWAY_TRIP_RELAY = https:/$()/whichway-trips.<account>.workers.dev`
   (the `$()` keeps `//` from starting an xcconfig comment) and rebuild the app. Release builds carry it too, so
   TestFlight testers' trips arrive the same way.

`make relay-health` asks the deployed Worker whether both secrets are in place and whether its token can see the
repository (`/v1/health?probe=1`: `repoStatus` 200 and `canPush` true; 404 means the token was not granted that
repository, 401 that the token is wrong).

## The API

| | |
|---|---|
| `POST /v1/trips` | body: one trip observation, as the app records it (JSON) |
| `POST /v1/traces` | body: one motion trace (JSON, `startTs`, `columns`, `seconds`) |
| `POST /v1/reports` | body: one rider report (JSON: `id`, `ts`, `kind`, `route`, `stop`, optional `sub`, `dir`, `trip`, `source`, `confidence`) |
| `GET /v1/reports?since=<ts>` | the rider reports of the last two days from `since` (default the last two hours); public, CORS open, no key |
| `GET /v1/health` | `{ok, repo, configured}` |

Headers: `X-WhichWay-Key` (the app key) and `X-WhichWay-Install` (the phone's random telemetry id). Replies:
201 created, 200 updated or unchanged (sending the same trip again is fine; a richer record of the same trip
replaces the file), 400 for a body the review could not use, 401 for a wrong key, 413 over size (256 KB for a
trip, 4 MB for a trace), 429 too many (60 a minute per phone, 120 per address), 502 when GitHub refused the
write (the reply says why: usually the token).

## Rider reports

A rider can report what they see (`held`, `delay`, `moving`, `long_wait`, `crowded`, `incident`, `skipped`,
`all_good`), pinned to the line, direction and stop the app detected. The relay replaces the phone's install id with
two keyed hashes before anything is stored: `reporter`, stable, only in the archived file
(`reports/<y>/<m>/<d>/<ts>-<id>.json` in the data repository), so the pipeline can learn whose reports the feed
backs up; and `rider`, which changes every New York day, in the public list, enough to count distinct riders. The
same rider, kind and stop again within two minutes is answered 200 `repeat` and stored nowhere. Ten reports a
minute per phone (`RATE_REPORT`).

The public list the Atlas map reads lives in Workers KV. Once:

    npx wrangler kv namespace create REPORTS      # paste the id into the commented [[kv_namespaces]] in wrangler.toml
    openssl rand -hex 24 | npx wrangler secret put REPORT_SALT

Without the KV binding reports are still archived and the list is empty; without `REPORT_SALT` the hashes are keyed
with the app key.

The hourly pipeline keeps every report (`python -m pipeline.reports`, into `reports/reports.jsonl` on the data branch)
and weighs each reporter by how often the record backs them up. For that it needs the stable `reporter` hash, which
the list carries only with a read key the pipeline holds:

    openssl rand -hex 24 | tee /dev/stderr | npx wrangler secret put READ_KEY
    # the same value as the repository secret WHICHWAY_REPORTS_READ_KEY, and the relay's address as the repository
    # variable WHICHWAY_RELAY (Settings › Secrets and variables › Actions)

## What it does not do

It keeps no copy and no log of its own: the repository is the record. It does not authenticate riders: the app
key is in every copy of the app, so anyone who extracts it can write files into the data repository at the rate
limit; the repository is private and separate from the code, the files are validated for shape and size, and the
key can be rotated (a new `APP_KEY` secret and a new build; old builds then get 401 and keep their trips on the
phone). Rotate the GitHub token the same way (`wrangler secret put GITHUB_TOKEN`).

## Tests and changes

`node --test` in this folder (or `make relay-test`) runs the Worker against a fake GitHub: the layout, the
unchanged/updated handling, every refusal, the rate limit and a GitHub error. No Cloudflare runtime is needed.
`npx wrangler dev` runs it locally with real bindings; `npx wrangler tail` streams a deployed Worker's requests.
