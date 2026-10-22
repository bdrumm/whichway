// Data for the map app: where the published JSON lives, the live train engine and the derived live insights.
//
// Sources, in order of preference:
//   static tables  ?data=<url>  ->  ../data/ (the built site or `mta-insights serve`)  ->  the gh-pages branch on GitHub
//   train positions  the MTA GTFS-Realtime feeds polled from the browser (or the recorded feeds of a synthetic build)
//                    -> per line, positions from today's schedule when a feed is unreachable (labelled "scheduled")
import { createClientLive, lineBoard, trainProgress, stationIndex, schedHeadwayAt } from "../rt-client.js";
import { buildLine } from "./geo.js";

export const ROUTE_COLORS = { "1": "#ee352e", "2": "#ee352e", "3": "#ee352e", "4": "#00933c", "5": "#00933c", "6": "#00933c", "6X": "#00933c", "7": "#b933ad", "7X": "#b933ad",
  A: "#0039a6", C: "#0039a6", E: "#0039a6", B: "#ff6319", D: "#ff6319", F: "#ff6319", FX: "#ff6319", M: "#ff6319", G: "#6cbe45", J: "#996633", Z: "#996633",
  L: "#a7a9ac", N: "#fccc0a", Q: "#fccc0a", R: "#fccc0a", W: "#fccc0a", S: "#808183", GS: "#808183", FS: "#808183", H: "#808183", SI: "#0039a6" };
export const DARK_TEXT = new Set(["N", "Q", "R", "W"]);
export const baseRoute = r => (r === "6X" || r === "7X" || r === "FX") ? r.slice(0, -1) : r;
export const routeColor = r => ROUTE_COLORS[r] || "#6b6b6b";

// ---------------------------------------------------------------- static tables
export async function resolveDataBase() {
  const override = new URLSearchParams(location.search).get("data");
  if (override) return { base: override.endsWith("/") ? override : override + "/", source: "override" };
  for (const cand of ["../data/", "data/"]) {
    try { const r = await fetch(cand + "index.json", { cache: "no-cache", method: "HEAD" }); if (r.ok) return { base: cand, source: "same-origin" }; } catch {}
  }
  // GitHub Pages serving the source branch, or a local static server over the repository: the published data branch
  const m = location.hostname.match(/^([^.]+)\.github\.io$/i);
  const repo = m ? location.pathname.split("/").filter(Boolean)[0] : null;
  return { base: `https://raw.githubusercontent.com/${m ? m[1] : "bdrumm"}/${repo || "whichway"}/gh-pages/data/`, source: "gh-pages" };
}

export function makeLoader(base) {
  const cache = new Map();
  return function load(path, { optional = true } = {}) {
    if (!cache.has(path)) cache.set(path, fetch(base + path, { cache: "no-cache" }).then(r => { if (!r.ok) throw new Error(`${path}: HTTP ${r.status}`); return r.json(); })
      .catch(e => { if (optional) { console.warn(e); return null; } throw e; }));
    return cache.get(path);
  };
}

// ---------------------------------------------------------------- schedule positions (fallback)
export const cumRun = line => { const c = [0]; for (let i = 0; i < line.stops.length - 1; i++) c.push(c[i] + (line.run_sec[i] ?? 90)); return c; };

/** Trains of one line where today's schedule puts them at ``now``: [{trip_id, idx, points}] */
export function scheduledTrains(line, entries, cum, now) {
  const out = [];
  for (const [stem, li, ts] of entries || []) {
    const c = cum[li] - (ts - now);           // scheduled running seconds covered from the first stop
    if (c < 0 || c > cum[li]) continue;
    let j = 0; while (j < li && cum[j + 1] <= c) j++;
    const span = cum[j + 1] - cum[j], idx = j + (span > 0 && j < li ? (c - cum[j]) / span : 0);
    const points = []; for (let i = Math.ceil(idx); i <= li; i++) points.push([i, ts - (cum[li] - cum[i])]);
    out.push({ trip_id: stem, idx, points, last_idx: li });
  }
  return out;
}

// ---------------------------------------------------------------- the live engine
/**
 * Polls every feed, builds a line board for each exported line and keeps:
 *   engine.trains     one record per train with route, line key, the board's view and a position function
 *   engine.lines      per line key: schedule line, geometry, board, scheduled headway, mode ("live" | "scheduled")
 *   engine.events     live insights detected across polls (holds, stalls, gaps, track changes), newest first
 */
export function createEngine({ base, load, onUpdate, onStatus }) {
  const E = { schedule: null, lineSched: {}, geometry: {}, lines: {}, trains: [], events: [], stations: null, alerts: null, alertsError: null,
    mode: "loading", boardNow: 0, wallAtBoard: 0, demoOffset: 0, feedTs: null, feedInfo: [], failedFeeds: new Set(), polls: 0, model: null, history: [], startedAt: Date.now() / 1000 };
  const active = new Map();   // event key -> event (open events, updated in place)

  E.now = () => Date.now() / 1000 + E.demoOffset;
  E.age = () => E.now() - E.boardNow;

  async function init() {
    const [schedule, lines, geometry] = await Promise.all([load("client_schedule.json", { optional: false }), load("client_lines.json"), load("client_geometry.json", { optional: false })]);
    E.schedule = schedule; E.lineSched = (lines && lines.lines) || {};
    if (schedule.demo_now) E.demoOffset = schedule.demo_now - Date.now() / 1000;
    for (const [key, ln] of Object.entries(schedule.lines)) {
      const g = geometry.lines[key]; if (!g) continue;
      const [route, dir] = key.split("_");
      E.lines[key] = { key, route, dir, line: ln, geo: buildLine(g), cum: cumRun(ln), board: null, mode: "scheduled", terminus: ln.names[ln.names.length - 1], origin: ln.names[0] };
    }
    E.stations = stationIndex(schedule);
    for (const st of E.stations.stations.values()) { const m = st.members.find(mm => E.lines[mm.key]); st.lngLat = m ? E.lines[m.key].geo.stop(m.idx) : null; }
    E.geometry = geometry;
  }

  function rebuild(feeds) {
    const now = E.now(); E.boardNow = now; E.wallAtBoard = Date.now() / 1000;
    const trains = [];
    for (const L of Object.values(E.lines)) {
      const feedKey = (E.schedule.route_feeds || {})[L.route];
      const live = feeds && feedKey && feeds[feedKey] && !E.failedFeeds.has(feedKey);
      L.hw = schedHeadwayAt(E.schedule, E.lineSched, [L.key], L.line.stops[Math.floor(L.line.stops.length / 2)], now);
      if (live) {
        L.mode = "live";
        L.board = lineBoard(E.schedule, E.lineSched[L.key], { [feedKey]: feeds[feedKey] }, L.route, L.dir, now);
        for (const t of L.board ? L.board.trains : []) trains.push({ ...t, id: `${L.key}|${t.trip_id}`, key: L.key, dir: L.dir, kind: "live" });
      } else {
        L.mode = "scheduled";
        const sched = scheduledTrains(L.line, E.lineSched[L.key], L.cum, now);
        L.board = { route: L.route, direction: L.dir, now, stops: L.line.stops.map((s, i) => ({ stop_id: s, name: L.line.names[i] })),
          trains: sched.map(s => ({ trip_id: s.trip_id, route: L.route, points: s.points, next_idx: Math.ceil(s.idx), next_name: L.line.names[Math.ceil(s.idx)], eta_ts: s.points[0] ? s.points[0][1] : null,
            lateness_sec: null, effective_lateness_sec: null, position: null, sched_idx: s.idx })), n_holding: 0, n_stalled: 0 };
        for (const t of L.board.trains) trains.push({ ...t, id: `${L.key}|${t.trip_id}`, key: L.key, dir: L.dir, kind: "scheduled" });
      }
    }
    for (const t of trains) {
      const L = E.lines[t.key];
      t.progress = age => t.kind === "scheduled" ? { idx: Math.min(L.line.stops.length - 1, t.sched_idx + age / Math.max(30, L.line.run_sec[Math.floor(t.sched_idx)] ?? 90)), state: "scheduled", since: null }
        : trainProgress(t, age, L.line);
      t.late = t.effective_lateness_sec ?? t.lateness_sec;
    }
    E.trains = trains;
    detect(now);
    // replay history: where every train was at this poll (positions only, kept for two hours)
    E.history.push({ ts: now, mode: E.mode, trains: trains.map(t => { const p = t.progress(0); return { id: t.id, key: t.key, route: t.route, dir: t.dir, idx: p.idx, state: p.state, late: t.late, kind: t.kind }; }) });
    while (E.history.length && E.history[0].ts < now - 7200) E.history.shift();
  }

  /** Train positions at a past moment: interpolated between the recorded polls around it, else today's schedule. */
  E.positionsAt = t => {
    const H = E.history;
    if (H.length && t >= H[0].ts) {
      let i = H.length - 1; while (i > 0 && H[i].ts > t) i--;
      const a = H[i], b = H[i + 1];
      if (!b) return { source: a.mode, trains: a.trains };
      const f = (t - a.ts) / Math.max(1, b.ts - a.ts), nb = new Map(b.trains.map(x => [x.id, x]));
      return { source: a.mode, trains: a.trains.map(x => { const y = nb.get(x.id); return y && y.idx >= x.idx ? { ...x, idx: x.idx + f * (y.idx - x.idx) } : x; }) };
    }
    const trains = [];
    for (const L of Object.values(E.lines)) for (const s of scheduledTrains(L.line, E.lineSched[L.key], L.cum, t))
      trains.push({ id: `${L.key}|${s.trip_id}`, key: L.key, route: L.route, dir: L.dir, idx: s.idx, state: "scheduled", late: null, kind: "scheduled" });
    return { source: "scheduled", trains };
  };

  // ---- live insights: open an event when a condition appears, keep it updated, close it when it clears
  function upsert(key, now, make) {
    let ev = active.get(key);
    if (!ev) { ev = { key, first_ts: now, ...make() }; active.set(key, ev); E.events.unshift(ev); }
    else Object.assign(ev, make());
    ev.last_ts = now; ev.open = true; ev.seen = E.polls;
  }
  function detect(now) {
    E.polls++;
    for (const t of E.trains) {
      if (t.kind !== "live") continue;
      const L = E.lines[t.key], p = t.position;
      if (p && p.holding) upsert(`hold|${t.id}`, now, () => ({ kind: "hold", severity: p.since_sec >= 600 ? "high" : "medium", route: t.route, lineKey: t.key, trainId: t.id, stopIdx: p.stop_idx,
        title: `${t.route} train held at ${p.stop_name}`, text: `Stopped ${Math.round(p.since_sec / 60)} min${L ? ` · toward ${L.terminus}` : ""}${t.train_id ? ` · ${t.train_id}` : ""}`, since: p.since_sec }));
      if (p && p.stalled) upsert(`stall|${t.id}`, now, () => ({ kind: "stall", severity: "high", route: t.route, lineKey: t.key, trainId: t.id, stopIdx: p.stop_idx,
        title: `${t.route} train stalled before ${p.stop_name}`, text: `${Math.round(p.since_sec / 60)} min on a ${Math.round((p.expected_run_sec || 0) / 60 * 10) / 10} min run${L ? ` · toward ${L.terminus}` : ""}`, since: p.since_sec }));
      if (t.track_changed) upsert(`track|${t.id}`, now, () => ({ kind: "track", severity: "low", route: t.route, lineKey: t.key, trainId: t.id, stopIdx: t.next_idx,
        title: `${t.route} train rerouted onto another track`, text: `Track change at ${t.next_name}${L ? ` · toward ${L.terminus}` : ""}` }));
    }
    // service gaps: scheduled running time between consecutive trains vs the scheduled headway
    for (const L of Object.values(E.lines)) {
      if (L.mode !== "live" || !L.hw || !L.board) continue;
      const pos = L.board.trains.map(t => ({ t, idx: trainProgress(t, 0, L.line).idx })).sort((a, b) => b.idx - a.idx);
      for (let i = 1; i < pos.length; i++) {
        const a = pos[i - 1], b = pos[i]; if (a.idx >= L.line.stops.length - 1.2) continue;
        const ca = L.cum[Math.floor(a.idx)] + (a.idx % 1) * ((L.cum[Math.floor(a.idx) + 1] ?? L.cum[Math.floor(a.idx)]) - L.cum[Math.floor(a.idx)]);
        const cb = L.cum[Math.floor(b.idx)] + (b.idx % 1) * ((L.cum[Math.floor(b.idx) + 1] ?? L.cum[Math.floor(b.idx)]) - L.cum[Math.floor(b.idx)]);
        const gap = ca - cb;
        if (b.idx >= 2 && gap >= Math.max(2.5 * L.hw, 900)) upsert(`gap|${L.key}|${b.t.trip_id}`, now, () => ({ kind: "gap", severity: gap >= 3 * L.hw ? "high" : "medium", route: L.route, lineKey: L.key, trainId: `${L.key}|${b.t.trip_id}`,
          stopIdx: Math.round((a.idx + b.idx) / 2), title: `${Math.round(gap / 60)} min gap in ${L.route} service`, text: `Between ${L.line.names[Math.ceil(b.idx)]} and ${L.line.names[Math.ceil(a.idx)]} toward ${L.terminus} · scheduled every ${Math.round(L.hw / 60)} min`, gap }));
      }
    }
    for (const ev of active.values()) if (ev.seen !== E.polls) { ev.open = false; ev.ended_ts = now; active.delete(ev.key); }
    if (E.events.length > 300) E.events.length = 300;
  }

  let failures = 0, client = null;
  async function start() {
    onStatus && onStatus({ mode: "loading" });
    await init();
    // schedule positions immediately, the live feeds replace them line by line as they arrive
    E.mode = "scheduled"; rebuild(null); onUpdate(E);
    const forceSchedule = new URLSearchParams(location.search).has("scheduled");
    if (forceSchedule) { setInterval(() => { rebuild(null); onUpdate(E); }, 30000); return E; }
    const feedKeys = Object.keys(E.schedule.feeds || {});
    let failedThisTick = new Set();
    client = createClientLive({ base, intervalMs: 30000, feedKeys: () => feedKeys,
      fetchImpl: async (u, o) => {
        if (u.endsWith("client_schedule.json")) return new Response(JSON.stringify(E.schedule));
        const key = feedKeys.find(k => E.schedule.feeds[k] === u || base + E.schedule.feeds[k] === u);
        if (!key) return fetch(u, o);
        try { const r = await fetch(u, o); if (!r.ok) throw new Error(`HTTP ${r.status}`); return r; }
        catch (e) { failedThisTick.add(key); return new Response(new Uint8Array(0)); }   // that line falls back to the schedule
      },
      onUpdate: async (board, schedule, feeds) => {
        E.failedFeeds = failedThisTick; failedThisTick = new Set();
        const ok = feedKeys.filter(k => !E.failedFeeds.has(k));
        E.mode = ok.length === 0 ? "scheduled" : schedule.demo_now ? "demo" : "live";
        if (E.mode === "scheduled") failures++; else failures = 0;
        E.feedInfo = board.feeds; E.feedTs = board.feed_ts; E.model = board.model;
        if (board.alerts) { E.alerts = board.alerts; E.alertsError = board.alerts_error; }
        rebuild(ok.length ? feeds : null);
        onUpdate(E);
      },
      onError: e => { failures++; console.warn("live feeds:", e); E.mode = "scheduled"; rebuild(null); onUpdate(E); onStatus && onStatus({ mode: "scheduled", error: String(e.message || e) }); },
    });
    client.start();
    return E;
  }
  E.start = start;
  E.refresh = () => client && client.refresh();
  E.trainById = id => E.trains.find(t => t.id === id);
  return E;
}

// ---------------------------------------------------------------- live line health
const median = a => { if (!a.length) return null; const s = [...a].sort((x, y) => x - y); return s[Math.floor(s.length / 2)]; };

/** Per route (both directions, express variants folded in): trains, holds, stalls, lateness, gaps, alerts, status. */
export function routeHealth(E) {
  const by = new Map();
  const get = r => { let h = by.get(r); if (!h) { h = { route: r, trains: 0, byDir: { N: 0, S: 0 }, holding: 0, stalled: 0, late: [], gaps: 0, alerts: [], live: false, keys: [] }; by.set(r, h); } return h; };
  for (const L of Object.values(E.lines)) { const h = get(baseRoute(L.route)); h.keys.push(L.key); if (L.mode === "live") h.live = true; }
  for (const t of E.trains) {
    const h = get(baseRoute(t.route)); h.trains++; h.byDir[t.dir] = (h.byDir[t.dir] || 0) + 1;
    if (t.position && t.position.holding) h.holding++;
    if (t.position && t.position.stalled) h.stalled++;
    if (t.late != null) h.late.push(t.late);
  }
  for (const ev of E.events) if (ev.open && ev.kind === "gap") get(baseRoute(ev.route)).gaps++;
  for (const a of E.alerts || []) if (a.kind === "delay") for (const r of a.routes || []) if (by.has(baseRoute(r))) get(baseRoute(r)).alerts.push(a);
  for (const h of by.values()) {
    h.median_late = median(h.late);
    h.share_late = h.late.length ? h.late.filter(x => x >= 300).length / h.late.length : null;
    const score = (h.alerts.length ? 3 : 0) + h.stalled * 2 + h.holding + h.gaps * 1.5 + (h.median_late != null ? Math.max(0, h.median_late - 60) / 90 : 0);
    h.score = score;
    h.status = !h.live ? "scheduled" : (h.alerts.length || h.stalled >= 2 || score >= 6) ? "disrupted" : score >= 2.5 ? "degraded" : "good";
  }
  return by;
}

export const ROUTE_ORDER = ["1", "2", "3", "4", "5", "6", "7", "A", "C", "E", "B", "D", "F", "M", "G", "J", "Z", "L", "N", "Q", "R", "W", "GS", "FS", "H", "SI"];
export const routeSort = (a, b) => (ROUTE_ORDER.indexOf(a) + 1 || 99) - (ROUTE_ORDER.indexOf(b) + 1 || 99) || a.localeCompare(b);
