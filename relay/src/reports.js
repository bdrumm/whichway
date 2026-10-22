// Rider reports: what a rider saw (a held train, a long wait, crowding, an incident, or that all is well), pinned to
// the line, direction and stop the app detected. The relay keeps the last two days in one KV value for the map and
// the pipeline to read, and archives each report into the data repository beside the trips.
//
//   POST /v1/reports            body: one report (JSON); app key and install id as for trips
//   GET  /v1/reports?since=ts   the recent reports, newest last; public, CORS open, no reporter identity
//
// The phone's install id never leaves the relay: the archive carries a stable keyed hash of it (`reporter`, so the
// pipeline can learn which reporters the feed backs up) and the public list a hash that changes every New York day
// (`rider`, enough to count distinct riders and drop repeats, not to follow one rider from day to day).

export const REPORT_KINDS = {
  delay: [],
  held: [],
  moving: [],
  long_wait: [],
  crowded: ["some", "packed", "cant_board"],
  incident: ["police", "medical", "door", "signal", "track", "other"],
  skipped: ["skipped_stop", "rerouted", "express", "local"],
  all_good: [],
};
export const REPORT_SOURCES = ["trip", "station", "manual"];

/** How long a report stays on the map, by kind (seconds); the public list keeps everything for RECENT_SEC. */
export const REPORT_TTL = { delay: 1800, held: 1200, moving: 900, long_wait: 1500, crowded: 1800, incident: 2700, skipped: 1800, all_good: 900 };
export const RECENT_SEC = 48 * 3600;
const RECENT_KEY = "recent";
const RECENT_MAX = 5000;
/** The same rider, kind and stop again within this many seconds is a repeat, not a second report. */
const REPEAT_SEC = 120;

const ID_RE = /^[A-Za-z0-9-]{8,64}$/;
const ROUTE_RE = /^[0-9A-Z]{1,3}X?$/;
const STOP_RE = /^[0-9A-Z]{2,6}[NS]?$/;
const TRIP_RE = /^[A-Za-z0-9_.:+-]{1,80}$/;

export function validateReport(o, nowSec, maxAgeDays) {
  if (!o || typeof o !== "object" || Array.isArray(o)) return "not a JSON object";
  if (typeof o.id !== "string" || !ID_RE.test(o.id)) return "id missing";
  if (typeof o.ts !== "number" || !Number.isFinite(o.ts)) return "ts missing";
  if (o.ts < nowSec - maxAgeDays * 86400 || o.ts > nowSec + 600) return "ts out of range";
  if (!Object.prototype.hasOwnProperty.call(REPORT_KINDS, o.kind)) return "kind unknown";
  if (o.sub !== undefined && o.sub !== null && !REPORT_KINDS[o.kind].includes(o.sub)) return "sub unknown";
  if (typeof o.route !== "string" || !ROUTE_RE.test(o.route)) return "route missing";
  if (o.dir !== undefined && o.dir !== null && o.dir !== "N" && o.dir !== "S") return "dir malformed";
  if (typeof o.stop !== "string" || !STOP_RE.test(o.stop)) return "stop missing";
  if (o.trip !== undefined && o.trip !== null && (typeof o.trip !== "string" || !TRIP_RE.test(o.trip))) return "trip malformed";
  if (o.source !== undefined && !REPORT_SOURCES.includes(o.source)) return "source unknown";
  if (o.confidence !== undefined && o.confidence !== null && (typeof o.confidence !== "number" || !(o.confidence >= 0 && o.confidence <= 1))) return "confidence malformed";
  return null;
}

async function hmacHex(secret, text, chars) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(text)));
  return Array.from(sig.slice(0, chars / 2), (b) => b.toString(16).padStart(2, "0")).join("");
}

export function nyDate(tsSec) {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(tsSec * 1000));
}

/** The stable reporter hash (archive) and the day's rider hash (public), both keyed by the Worker's salt. */
export async function reporterIds(env, install, tsSec) {
  const salt = env.REPORT_SALT || env.APP_KEY;
  return { reporter: await hmacHex(salt, `reporter|${install}`, 16), rider: await hmacHex(salt, `rider|${nyDate(tsSec)}|${install}`, 12) };
}

export function reportPath(tsSec, id) {
  const [y, m, d] = nyDate(tsSec).split("-");
  return `reports/${y}/${m}/${d}/${Math.trunc(tsSec)}-${id}.json`;
}

/** The fields everyone may see: what, where, when, and the day's rider hash. */
export function publicReport(o, rider, receivedTs) {
  const out = { id: o.id, ts: Math.round(o.ts), kind: o.kind, route: o.route, stop: o.stop, rider, received_ts: Math.round(receivedTs) };
  if (o.sub) out.sub = o.sub;
  if (o.dir) out.dir = o.dir;
  if (o.trip) out.trip = o.trip;
  if (o.source) out.source = o.source;
  if (typeof o.confidence === "number") out.confidence = Math.round(o.confidence * 100) / 100;
  return out;
}

export async function readRecent(kv) {
  if (!kv) return [];
  try {
    const v = await kv.get(RECENT_KEY, "json");
    return Array.isArray(v) ? v : [];
  } catch {
    return [];
  }
}

/** The same report again, or the same rider, kind and stop within two minutes. */
export function isRepeat(list, rep) {
  return list.some((r) => r.id === rep.id || (r.rider === rep.rider && r.kind === rep.kind && r.stop === rep.stop && Math.abs(r.ts - rep.ts) < REPEAT_SEC));
}

/**
 * Adds a report to the recent list (dropping what is over two days old); a repeat is not added. Two reports landing
 * at the same instant can race and one be lost from the list; the archive still has it.
 */
export async function addRecent(kv, rep, nowSec) {
  if (!kv) return "no-store";
  const list = (await readRecent(kv)).filter((r) => nowSec - r.ts < RECENT_SEC);
  if (isRepeat(list, rep)) return "repeat";
  list.push(rep);
  list.sort((a, b) => a.ts - b.ts);
  await kv.put(RECENT_KEY, JSON.stringify(list.slice(-RECENT_MAX)));
  return "added";
}

export const CORS = { "access-control-allow-origin": "*", "access-control-allow-methods": "GET, OPTIONS", "access-control-max-age": "86400" };

/** GET /v1/reports: the recent list from `since` (default: the last two hours), cached briefly at the edge. */
export async function listReports(env, url, nowSec) {
  const since = Number(url.searchParams.get("since") || nowSec - 7200);
  const list = (await readRecent(env.REPORTS)).filter((r) => r.ts >= (Number.isFinite(since) ? since : nowSec - 7200) && nowSec - r.ts < RECENT_SEC);
  return new Response(JSON.stringify({ ok: true, generated_ts: Math.round(nowSec), ttl: REPORT_TTL, reports: list }), {
    status: 200,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "public, max-age=20", ...CORS },
  });
}
