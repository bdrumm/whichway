// Rider reports on the Atlas: what riders say they see (a held train, a long wait, crowding, an incident, or that
// all is well), read from the trip relay's public list (GET /v1/reports), grouped by place, and set against what
// the browser detects from the feeds, so a detection riders back up says so and one they dispute is dimmed.
//
// The relay's address comes from <meta name="whichway-relay"> or ?relay=…; #reports=demo shows labelled sample
// reports built from the live detections, to show the idea before there are riders.

export const KIND_LABEL = { held: "Held", delay: "Running slow", moving: "Moving again", long_wait: "Long wait", crowded: "Crowded",
  incident: "Incident", skipped: "Skipped / rerouted", all_good: "All good" };
export const SUB_LABEL = { some: "busy", packed: "packed", cant_board: "couldn't board", police: "police", medical: "sick passenger", door: "doors",
  signal: "signals", track: "track", other: "other", skipped_stop: "skipped a stop", rerouted: "rerouted", express: "running express", local: "running local" };
/** How long a report stays on the map (s), as the relay says; this is the fallback. */
export const DEFAULT_TTL = { delay: 1800, held: 1200, moving: 900, long_wait: 1500, crowded: 1800, incident: 2700, skipped: 1800, all_good: 900 };

/** Which live detections a kind of report backs up, and which it disputes. */
const CONFIRMS = { held: ["hold", "stall"], delay: ["hold", "stall", "gap"], long_wait: ["gap"], skipped: ["track"], incident: ["hold", "stall"] };
const DISPUTES = { all_good: ["hold", "stall", "gap"], moving: ["hold", "stall"] };
const NEAR_STOPS = 2, NEAR_SEC = 600;

/** "A41S" → "A41": reports group by station (the phone may send the platform or the station). */
export function normStop(s) { s = String(s || ""); return s.length === 4 && /[NS]$/.test(s) ? s.slice(0, 3) : s; }
/** Where a station sits on a line, whose stops are platforms ("A41S"). */
export function stopIndex(L, stop) { return L.line.stops.findIndex(s => normStop(s) === stop); }

export function relayAddress(doc = globalThis.document, loc = globalThis.location) {
  try {
    const q = new URLSearchParams(loc.search).get("relay");
    const m = doc.querySelector('meta[name="whichway-relay"]');
    const u = (q || (m && m.content) || "").trim();
    return /^https:\/\//.test(u) ? u.replace(/\/$/, "") : "";
  } catch { return ""; }
}

/** The reports still on the map at `now`, by each kind's time to live. */
export function liveReports(reports, now, ttl = DEFAULT_TTL) {
  return (reports || []).filter(r => r && now - r.ts >= -120 && now - r.ts < (ttl[r.kind] || 1200));
}

/**
 * Groups reports at one place and of one kind: { id, kind, route, dir, stop, lineKey, count, riders, first_ts, last_ts,
 * subs, demo }. A rider counts once per group however often they reported.
 */
export function groupReports(reports) {
  const g = new Map();
  for (const r of reports) {
    const stop = normStop(r.stop), id = `${r.kind}|${r.route}|${r.dir || ""}|${stop}`;
    let x = g.get(id);
    if (!x) { x = { id, kind: r.kind, route: r.route, dir: r.dir || null, stop, lineKey: r.dir ? `${r.route}_${r.dir}` : null, count: 0, riderSet: new Set(), first_ts: r.ts, last_ts: r.ts, subs: {}, demo: !!r.demo }; g.set(id, x); }
    x.riderSet.add(r.rider || r.id); x.count = x.riderSet.size;
    x.first_ts = Math.min(x.first_ts, r.ts); x.last_ts = Math.max(x.last_ts, r.ts);
    if (r.sub) x.subs[r.sub] = (x.subs[r.sub] || 0) + 1;
  }
  return [...g.values()].map(({ riderSet, ...x }) => x).sort((a, b) => b.last_ts - a.last_ts);
}

/** The lines a group could mean: its own line and direction, else both directions of its route. */
function groupLines(gr, lines) {
  if (gr.lineKey) return lines[gr.lineKey] ? [lines[gr.lineKey]] : [];
  return ["N", "S"].map(d => lines[`${gr.route}_${d}`]).filter(Boolean);
}

/**
 * Sets the groups against the live detections. Returns { byEvent: Map(event key → {confirm, dispute}), byGroup:
 * Map(group id → {event, verdict: "confirms" | "disputes" | null}) }. A group matches an open (or just cleared)
 * detection on the same line within two stops and ten minutes.
 */
export function matchDetections(groups, events, lines) {
  const byEvent = new Map(), byGroup = new Map();
  for (const gr of groups) {
    let best = null, bestD = Infinity, verdict = null;
    for (const L of groupLines(gr, lines)) {
      const si = stopIndex(L, gr.stop); if (si < 0) continue;
      for (const ev of events) {
        if (ev.lineKey !== L.key || ev.stopIdx == null) continue;
        const conf = (CONFIRMS[gr.kind] || []).includes(ev.kind), disp = (DISPUTES[gr.kind] || []).includes(ev.kind);
        if (!conf && !disp) continue;
        const end = ev.open ? Infinity : (ev.ended_ts ?? ev.last_ts ?? ev.first_ts);
        if (gr.last_ts < ev.first_ts - NEAR_SEC || gr.first_ts > end + NEAR_SEC) continue;
        const d = Math.abs(ev.stopIdx - si); if (d > NEAR_STOPS || d >= bestD) continue;
        best = ev; bestD = d; verdict = conf ? "confirms" : "disputes";
      }
    }
    byGroup.set(gr.id, { event: best, verdict });
    if (best) { const m = byEvent.get(best.key) || { confirm: 0, dispute: 0 }; m[verdict === "confirms" ? "confirm" : "dispute"] += gr.count; byEvent.set(best.key, m); }
  }
  return { byEvent, byGroup };
}

/** "Held · 3 riders" / "Crowded (packed) · 1 rider". */
export function groupTitle(gr) {
  const top = Object.entries(gr.subs).sort((a, b) => b[1] - a[1])[0];
  return `${KIND_LABEL[gr.kind] || gr.kind}${top ? ` (${SUB_LABEL[top[0]] || top[0]})` : ""} · ${gr.count} rider${gr.count === 1 ? "" : "s"}`;
}

/**
 * Sample reports for the demo: riders backing up some of the open detections, one disputing another, and a few
 * crowding reports, all marked `demo`. Deterministic for a given set of events, so the map does not flicker.
 */
export function demoReports(events, lines, now) {
  const out = [];
  let n = 0;
  const open = events.filter(e => e.open && e.stopIdx != null && lines[e.lineKey]);
  for (const ev of open.slice(0, 12)) {
    const L = lines[ev.lineKey], stop = L.line.stops[Math.min(L.line.stops.length - 1, Math.max(0, Math.round(ev.stopIdx)))];
    const [route, dir] = ev.lineKey.split("_");
    const h = [...ev.key].reduce((a, c) => (a * 31 + c.charCodeAt(0)) >>> 0, 7);
    if (h % 5 === 0) { out.push({ id: `demo-${n++}`, ts: now - 120 - (h % 300), kind: "all_good", route, dir, stop, rider: `d${h % 97}`, demo: true }); continue; }
    const kind = ev.kind === "gap" ? "long_wait" : ev.kind === "track" ? "skipped" : "held";
    const k = 1 + (h % 4);
    for (let i = 0; i < k; i++) out.push({ id: `demo-${n++}`, ts: Math.max(ev.first_ts, now - 60 * (i + 1) - (h % 200)), kind, route, dir, stop, rider: `d${(h + i) % 997}`, demo: true });
  }
  for (const L of Object.values(lines).filter(L => L.mode === "live").slice(0, 40)) {
    const h = [...L.key].reduce((a, c) => (a * 17 + c.charCodeAt(0)) >>> 0, 3);
    if (h % 9) continue;
    const stop = L.line.stops[h % L.line.stops.length], [route, dir] = L.key.split("_");
    out.push({ id: `demo-${n++}`, ts: now - 300 - (h % 600), kind: "crowded", sub: h % 2 ? "packed" : "some", route, dir, stop, rider: `c${h % 991}`, demo: true });
  }
  return out;
}

/** Polls the relay's list every 30 s (the feeds' cadence); `onChange(reports, info)` after each answer. */
export function createReportsSource({ relay, demo, onChange, fetchImpl = globalThis.fetch, interval = 30000 }) {
  const S = { reports: [], ttl: DEFAULT_TTL, ok: null, error: null, relay, demo: !!demo, timer: null };
  async function poll() {
    if (!relay) { S.ok = null; onChange(S.reports, S); return; }
    try {
      const r = await fetchImpl(`${relay}/v1/reports?since=${Math.floor(Date.now() / 1000) - 3 * 3600}`, { cache: "no-store" });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const j = await r.json();
      S.reports = Array.isArray(j.reports) ? j.reports : []; if (j.ttl) S.ttl = { ...DEFAULT_TTL, ...j.ttl };
      S.ok = true; S.error = null;
    } catch (e) { S.ok = false; S.error = String(e.message || e); }
    onChange(S.reports, S);
  }
  S.start = () => { poll(); if (relay) S.timer = setInterval(poll, interval); return S; };
  return S;
}
