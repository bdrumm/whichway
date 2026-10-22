// Whichway Atlas: every train in the network live on a map, with line insights (left), the insights feed,
// a trip planner, station boards and the system research (right), and a timeline to replay the day.
import { fmt, stringline, heatmap, lineChart, barChart } from "../charts.js";
import { enumeratePaths, pathTrips } from "../rt-client.js";
import { resolveDataBase, makeLoader, createEngine, routeHealth, baseRoute, routeColor, routeSort, DARK_TEXT } from "./engine.js";
import { bboxOf } from "./geo.js";

// ---------------------------------------------------------------- small helpers
const $ = s => document.querySelector(s);
function h(tag, cls, text, parent) { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; if (parent) parent.appendChild(e); return e; }
const cssVar = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
const LABEL = { GS: "S", FS: "S", H: "S", SI: "SIR", "6X": "6", "7X": "7", FX: "F" };
const LINE_NAMES = { "1": "Broadway-7 Av Local", "2": "7 Av Express", "3": "7 Av Express", "4": "Lexington Av Express", "5": "Lexington Av Express", "6": "Lexington Av Local",
  "7": "Flushing", A: "8 Av Express", C: "8 Av Local", E: "8 Av Local", B: "6 Av Express", D: "6 Av Express", F: "6 Av Local", M: "6 Av Local", G: "Crosstown", J: "Nassau St",
  Z: "Nassau St Express", L: "14 St-Canarsie", N: "Broadway Express", Q: "Broadway Express", R: "Broadway Local", W: "Broadway Local", GS: "42 St Shuttle", FS: "Franklin Av Shuttle",
  H: "Rockaway Park Shuttle", SI: "Staten Island Railway" };
function bullet(route, parent, size = "") {
  const b = h("span", `bullet ${size}${DARK_TEXT.has(baseRoute(route)) || route === "G" || route === "L" ? " dark" : ""}${(LABEL[route] || route).length > 2 ? " xs-text" : ""}`, LABEL[route] || route, parent);
  b.style.background = routeColor(route); b.setAttribute("aria-label", `${route} line`); return b;
}
const NY = new Intl.DateTimeFormat("en-US", { timeZone: "America/New_York", hour: "2-digit", minute: "2-digit", hour12: false });
const NYS = new Intl.DateTimeFormat("en-US", { timeZone: "America/New_York", hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
const hhmm = ts => ts == null ? "–" : NY.format(new Date(ts * 1000));
function nyDayStart(ts) { const [hh, mm, ss] = NYS.format(new Date(ts * 1000)).split(":").map(Number); return ts - ((hh % 24) * 3600 + mm * 60 + ss); }
const mins = s => s == null ? "–" : `${Math.max(0, Math.round(s / 60))} min`;
function lateText(s) { if (s == null) return "no schedule match"; if (Math.abs(s) < 45) return "on time"; const m = Math.round(Math.abs(s) / 60); return s > 0 ? `${m} min late` : `${m} min early`; }
const lateClass = s => s == null ? "" : s >= 300 ? "late-crit" : s >= 120 ? "late-warn" : "late-good";
const ago = (ts, now) => { const d = Math.max(0, now - ts); return d < 60 ? "just now" : d < 3600 ? `${Math.round(d / 60)} min ago` : `${Math.round(d / 3600)} h ago`; };
const pct = v => v == null ? "–" : `${Math.round(v * 100)}%`;
function richText(text, parent) { // **bold** and [ROUTE] markup from the digest and alerts
  for (const part of String(text || "").split(/(\*\*[^*]+\*\*|\[[A-Z0-9]{1,3}\])/)) {
    if (!part) continue;
    if (part.startsWith("**")) h("b", null, part.slice(2, -2), parent);
    else if (/^\[[A-Z0-9]{1,3}\]$/.test(part)) { const r = part.slice(1, -1); if (routeColor(r) !== "#6b6b6b" || r === "SIR") bullet(r === "SIR" ? "SI" : r, parent, "sm"); else parent.appendChild(document.createTextNode(part)); }
    else parent.appendChild(document.createTextNode(part));
  }
}
function toast(msg, ms = 3500) { const t = $("#toast"); t.textContent = msg; t.hidden = false; clearTimeout(toast.t); toast.t = setTimeout(() => { t.hidden = true; }, ms); }

// ---------------------------------------------------------------- state
const S = { colorBy: "route", layers: { trains: true, stations: true, labels: true, hotspots: false, incidents: true },
  line: null, dir: "S", train: null, follow: false, station: null, tab: "feed", feed: "all", from: null, to: null, opt: 0, replay: null, lineSort: "map" };
const D = {};          // published tables
let load = null, dataBase = "", dataSource = "";
let E = null, map = null, mapReady = false, health = new Map(), stopLngLat = new Map();

function onEngine() {
  if (!stopLngLat.size) for (const L of Object.values(E.lines)) L.line.stops.forEach((s, i) => { if (!stopLngLat.has(s)) stopLngLat.set(s, L.geo.stop(i)); });
  health = routeHealth(E);
  if (mapReady && !map.getSource("lines").__filled) drawStatic();
  renderAll();
  if (S.follow && S.train) followTrain();
}
function renderAll() { renderHeader(); renderLeft(); renderRight(); renderInspector(); renderTimeline(); drawIncidents(); }

// ---------------------------------------------------------------- URL state
function readHash() {
  const q = new URLSearchParams(location.hash.slice(1));
  if (q.get("line")) S.line = q.get("line"); if (q.get("dir")) S.dir = q.get("dir");
  if (q.get("station")) S.station = q.get("station"); if (q.get("tab")) S.tab = q.get("tab");
  if (q.get("from")) S.from = q.get("from"); if (q.get("to")) S.to = q.get("to");
}
function writeHash() {
  const q = new URLSearchParams();
  if (S.line) { q.set("line", S.line); q.set("dir", S.dir); }
  if (S.station) q.set("station", S.station);
  if (S.tab !== "feed") q.set("tab", S.tab);
  if (S.from) q.set("from", S.from); if (S.to) q.set("to", S.to);
  history.replaceState(null, "", `${location.pathname}${location.search}${q.toString() ? "#" + q : ""}`);
}

// ---------------------------------------------------------------- chrome: header, docks, layers, theme, search
function initChrome() {
  document.querySelectorAll("[data-dock]").forEach(b => b.addEventListener("click", () => toggleDock(b.dataset.dock)));
  if (matchMedia("(max-width: 820px)").matches) { $("#left").classList.add("closed"); $("#right").classList.add("closed"); syncDockButtons(); }
  $("#left-back").addEventListener("click", () => selectLine(null));
  document.querySelectorAll("[data-tab]").forEach(b => b.addEventListener("click", () => setTab(b.dataset.tab)));
  setTab(S.tab, true);
  document.querySelectorAll("[data-layer]").forEach(cb => cb.addEventListener("change", () => { S.layers[cb.dataset.layer] = cb.checked; applyLayerVisibility(); }));
  document.querySelectorAll("[data-color]").forEach(b => b.addEventListener("click", () => {
    S.colorBy = b.dataset.color; document.querySelectorAll("[data-color]").forEach(x => { x.classList.toggle("on", x === b); x.setAttribute("aria-checked", x === b); });
    $("#legend").hidden = S.colorBy !== "late"; drawTrains();
  }));
  $("#layers .kicker").addEventListener("click", () => $("#layers").classList.toggle("collapsed"));
  $("#layers").classList.add("collapsed");
  $("#theme-toggle").addEventListener("click", () => {
    const root = document.documentElement, cur = root.dataset.theme || (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
    root.dataset.theme = cur === "dark" ? "light" : "dark"; try { localStorage.setItem("theme", root.dataset.theme); } catch {}
    setBasemap(); renderAll();
  });
  setInterval(() => { $("#clock").textContent = NYS.format(new Date((E ? E.now() : Date.now() / 1000) * 1000)); renderModePill(); }, 1000);
  combo($("#search"), $("#search-list"), () => searchItems(), it => {
    $("#search").value = ""; $("#search").blur();
    if (it.kind === "line") selectLine(it.value); else { selectStation(it.value, true); }
  });
}
function toggleDock(side, open) {
  const el = $(`#${side}`); const narrow = matchMedia("(max-width: 820px)").matches;
  const willOpen = open ?? el.classList.contains("closed");
  el.classList.toggle("closed", !willOpen);
  if (willOpen && narrow) $(`#${side === "left" ? "right" : "left"}`).classList.add("closed");
  syncDockButtons(); setTimeout(() => map && map.resize(), 240);
}
function syncDockButtons() { for (const s of ["left", "right"]) document.querySelector(`.dock-open.${s}`).classList.toggle("show", $(`#${s}`).classList.contains("closed")); }
function setTab(tab, quiet) {
  S.tab = tab; document.querySelectorAll("[data-tab]").forEach(b => b.setAttribute("aria-selected", b.dataset.tab === tab));
  routeFormBuilt = false; if (!quiet) { writeHash(); renderRight(); toggleDock("right", true); }
}

function searchItems() {
  const items = [];
  if (!E || !E.stations) return items;
  for (const r of [...health.keys()].sort(routeSort)) items.push({ kind: "line", value: r, label: `${LABEL[r] || r} · ${LINE_NAMES[r] || "line"}`, routes: [r], sub: "Line insights" });
  for (const st of E.stations.stations.values()) if (st.lngLat) items.push({ kind: "station", value: st.id, label: st.name, routes: st.routes.filter(r => !/X$/.test(r)) });
  return items;
}
/** A searchable picker: typing filters, arrows move, Enter or click picks. */
function combo(input, list, getItems, onPick) {
  let shown = [], active = 0;
  const render = () => {
    const q = input.value.trim().toLowerCase(); list.replaceChildren();
    if (!q) { list.hidden = true; return; }
    const all = getItems();
    shown = all.filter(it => it.label.toLowerCase().includes(q) || (it.kind === "line" && (LABEL[it.value] || it.value).toLowerCase() === q))
      .sort((a, b) => (a.label.toLowerCase().startsWith(q) ? 0 : 1) - (b.label.toLowerCase().startsWith(q) ? 0 : 1) || (a.kind === "line" ? -1 : 1) - (b.kind === "line" ? -1 : 1)).slice(0, 12);
    active = 0;
    shown.forEach((it, i) => {
      const li = h("li", i === active ? "active" : "", null, list); li.setAttribute("role", "option");
      const top = h("div", "row", null, li); top.style.gap = ".25rem";
      for (const r of it.routes.slice(0, 8)) bullet(r, top, "sm");
      h("strong", null, ` ${it.label}`, top);
      if (it.sub) h("div", "how", it.sub, li);
      li.addEventListener("mousedown", ev => { ev.preventDefault(); pick(i); });
    });
    list.hidden = !shown.length;
  };
  const pick = i => { const it = shown[i]; list.hidden = true; if (it) onPick(it); };
  input.addEventListener("input", render);
  input.addEventListener("focus", render);
  input.addEventListener("blur", () => setTimeout(() => { list.hidden = true; }, 120));
  input.addEventListener("keydown", ev => {
    if (list.hidden) return;
    if (ev.key === "ArrowDown" || ev.key === "ArrowUp") { ev.preventDefault(); active = (active + (ev.key === "ArrowDown" ? 1 : shown.length - 1)) % shown.length; [...list.children].forEach((li, i) => li.classList.toggle("active", i === active)); }
    else if (ev.key === "Enter") { ev.preventDefault(); pick(active); }
    else if (ev.key === "Escape") list.hidden = true;
  });
}

// ---------------------------------------------------------------- header
function renderModePill() {
  if (!E) return;
  const el = $("#mode"), txt = el.querySelector(".txt");
  el.className = "mode";
  if (S.replay != null) { el.classList.add("replay"); txt.textContent = `Replay · ${hhmm(S.replay)}`; return; }
  if (E.mode === "live" || E.mode === "demo") {
    el.classList.add("live");
    const age = E.feedTs ? Math.max(0, Math.round(E.now() - E.feedTs)) : null;
    const partial = E.failedFeeds.size ? ` · ${E.failedFeeds.size} feed${E.failedFeeds.size > 1 ? "s" : ""} on schedule` : "";
    txt.textContent = `${E.mode === "demo" ? "Recorded feeds" : "Live"}${age != null ? ` · feed ${age} s old` : ""}${partial}`;
  } else if (E.mode === "scheduled") { el.classList.add("scheduled"); txt.textContent = "Scheduled positions · live feeds unreachable"; }
  else txt.textContent = "Loading…";
}
function renderHeader() {
  renderModePill();
  const k = $("#kpis"); k.replaceChildren();
  const hs = [...health.values()], live = E.trains.filter(t => t.kind === "live");
  const add = (v, label, cls) => { const d = h("div", cls || "", null, k); h("b", null, String(v), d); d.appendChild(document.createTextNode(label)); };
  add(E.trains.length, live.length ? "trains" : "trains (scheduled)");
  if (live.length) {
    const lat = live.map(t => t.late).filter(v => v != null);
    add(lat.length ? pct(lat.filter(v => v < 300).length / lat.length) : "–", "within 5 min");
    add(live.filter(t => t.position && t.position.holding).length, "holding", "kpi-warn");
    add(live.filter(t => t.position && t.position.stalled).length, "stalled", "kpi-crit");
  }
  add(hs.filter(x => x.status === "disrupted").length, "lines disrupted", "kpi-crit");
  const alerts = liveAlerts().filter(a => a.kind === "delay");
  add(alerts.length, "delay alerts");
}

// ---------------------------------------------------------------- map
const STYLE_URL = dark => `https://basemaps.cartocdn.com/gl/${dark ? "dark-matter" : "positron"}-gl-style/style.json`;
const isDark = () => (document.documentElement.dataset.theme || (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light")) === "dark";
async function styleFor(dark) {
  try {
    const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 6000);
    const r = await fetch(STYLE_URL(dark), { signal: ctl.signal }); clearTimeout(t); if (!r.ok) throw new Error(r.status);
    return await r.json();
  } catch {   // no basemap reachable: a plain ground, the subway still draws on it
    return { version: 8, glyphs: "https://demotiles.maplibre.org/font/{fontstack}/{range}.pbf", sources: {}, layers: [{ id: "bg", type: "background", paint: { "background-color": dark ? "#0e1116" : "#eef1f4" } }] };
  }
}
const FONT = ["Montserrat SemiBold", "Open Sans Bold", "Noto Sans Regular"];
async function initMap() {
  if (!window.maplibregl) { toast("The map library did not load: check the network", 10000); return; }
  map = new maplibregl.Map({ container: "map", style: await styleFor(isDark()), center: [-73.93, 40.72], zoom: 10.7, minZoom: 9, maxZoom: 17, attributionControl: { compact: true }, hash: false, dragRotate: false, pitchWithRotate: false });
  map.touchZoomRotate.disableRotation();
  map.addControl(new maplibregl.NavigationControl({ showCompass: false }), "bottom-right");
  map.addControl(new maplibregl.GeolocateControl({ positionOptions: { enableHighAccuracy: false }, trackUserLocation: false }), "bottom-right");
  map.on("style.load", () => { addLayers(); mapReady = true; if (E && Object.keys(E.lines).length) { drawStatic(); renderAll(); } });
  bindMapEvents();
  setInterval(() => { if (mapReady && E) { drawTrains(); pulse(); } }, 250);
}
async function setBasemap() { if (!map) return; mapReady = false; map.setStyle(await styleFor(isDark()), { diff: false }); }

function addLayers() {
  const fc = { type: "FeatureCollection", features: [] };
  for (const id of ["lines", "path", "stations", "trains", "incidents", "hotspots"]) if (!map.getSource(id)) map.addSource(id, { type: "geojson", data: fc });
  const dark = isDark();
  map.addLayer({ id: "lines", type: "line", source: "lines", layout: { "line-cap": "round", "line-join": "round" },
    paint: { "line-color": ["get", "color"], "line-width": ["interpolate", ["linear"], ["zoom"], 9, 1.6, 12, 3, 15, 6], "line-opacity": 0.9,
      "line-offset": ["interpolate", ["linear"], ["zoom"], 10, ["*", ["get", "off"], 1.2], 13, ["*", ["get", "off"], 3], 16, ["*", ["get", "off"], 6]] } });
  map.addLayer({ id: "path-casing", type: "line", source: "path", layout: { "line-cap": "round", "line-join": "round" }, paint: { "line-color": dark ? "#ffffff" : "#15181c", "line-width": ["interpolate", ["linear"], ["zoom"], 9, 6, 15, 12] } });
  map.addLayer({ id: "path", type: "line", source: "path", layout: { "line-cap": "round", "line-join": "round" }, paint: { "line-color": ["get", "color"], "line-width": ["interpolate", ["linear"], ["zoom"], 9, 3.5, 15, 8] } });
  map.addLayer({ id: "incident-lines", type: "line", source: "incidents", filter: ["==", ["geometry-type"], "LineString"], layout: { "line-cap": "round" },
    paint: { "line-color": cssVar("--status-critical"), "line-width": ["interpolate", ["linear"], ["zoom"], 9, 5, 15, 14], "line-opacity": 0.55 } });
  map.addLayer({ id: "hotspots", type: "circle", source: "hotspots", layout: { visibility: "none" },
    paint: { "circle-color": ["match", ["get", "kind"], "hold", cssVar("--status-critical"), cssVar("--series-4")], "circle-opacity": 0.35, "circle-stroke-width": 1, "circle-stroke-color": ["match", ["get", "kind"], "hold", cssVar("--status-critical"), cssVar("--series-4")],
      "circle-radius": ["interpolate", ["linear"], ["zoom"], 9, ["*", ["get", "r"], 0.7], 14, ["*", ["get", "r"], 1.6]] } });
  map.addLayer({ id: "stations", type: "circle", source: "stations", minzoom: 11,
    paint: { "circle-color": dark ? "#0e1116" : "#ffffff", "circle-stroke-color": dark ? "#e8edf3" : "#15181c", "circle-stroke-width": ["interpolate", ["linear"], ["zoom"], 11, 1, 15, 2],
      "circle-radius": ["interpolate", ["linear"], ["zoom"], 11, 2, 13, 3.5, 16, 6] } });
  map.addLayer({ id: "station-labels", type: "symbol", source: "stations", minzoom: 13.2,
    layout: { "text-field": ["get", "name"], "text-font": FONT, "text-size": 11, "text-offset": [0.8, 0], "text-anchor": "left", "text-optional": true },
    paint: { "text-color": dark ? "#c8d2dd" : "#3b424b", "text-halo-color": dark ? "#0e1116" : "#ffffff", "text-halo-width": 1.4 } });
  map.addLayer({ id: "incident-pulse", type: "circle", source: "incidents", filter: ["==", ["geometry-type"], "Point"],
    paint: { "circle-color": "transparent", "circle-stroke-color": ["match", ["get", "severity"], "high", cssVar("--status-critical"), cssVar("--status-warning")], "circle-stroke-width": 2, "circle-radius": 14, "circle-stroke-opacity": 0.8 } });
  map.addLayer({ id: "trains", type: "circle", source: "trains",
    paint: { "circle-color": ["get", "fill"], "circle-radius": ["interpolate", ["linear"], ["zoom"], 9, ["case", ["get", "sel"], 6, 2.6], 12, ["case", ["get", "sel"], 11, 6], 15, ["case", ["get", "sel"], 14, 10]],
      "circle-stroke-color": ["get", "ring"], "circle-stroke-width": ["case", ["get", "sel"], 3, ["get", "ringW"]], "circle-opacity": ["get", "op"], "circle-stroke-opacity": ["get", "op"] } });
  map.addLayer({ id: "train-labels", type: "symbol", source: "trains", minzoom: 11.6,
    layout: { "text-field": ["get", "label"], "text-font": FONT, "text-size": ["interpolate", ["linear"], ["zoom"], 11.6, 8, 15, 12], "text-allow-overlap": true, "text-ignore-placement": true },
    paint: { "text-color": ["get", "ink"], "text-opacity": ["get", "op"] } });
  applyLayerVisibility();
}
function applyLayerVisibility() {
  if (!mapReady && !(map && map.getLayer("trains"))) return;
  const vis = on => on ? "visible" : "none";
  const set = (id, on) => map.getLayer(id) && map.setLayoutProperty(id, "visibility", vis(on));
  set("trains", S.layers.trains); set("train-labels", S.layers.trains && S.layers.labels);
  set("stations", S.layers.stations); set("station-labels", S.layers.stations);
  set("hotspots", S.layers.hotspots); set("incident-pulse", S.layers.incidents); set("incident-lines", S.layers.incidents);
  if (S.layers.hotspots) drawHotspots();
}

const OFFSETS = { "1": -1, "2": 0, "3": 1, "4": -1, "5": 0, "6": 1, A: -1, C: 0, E: 1, B: -1.5, D: -0.5, F: 0.5, M: 1.5, N: -1.5, Q: -0.5, R: 0.5, W: 1.5, J: -0.5, Z: 0.5 };
function drawStatic() {
  if (!mapReady || !E || !Object.keys(E.lines).length) return;
  const feats = [];
  for (const L of Object.values(E.lines)) {
    if (/X$/.test(L.route) || (L.dir === "S" && E.lines[`${L.route}_N`])) continue;   // one shape per route
    feats.push({ type: "Feature", properties: { route: L.route, base: baseRoute(L.route), color: routeColor(L.route), off: OFFSETS[L.route] || 0 }, geometry: { type: "LineString", coordinates: L.geo.full() } });
  }
  map.getSource("lines").setData({ type: "FeatureCollection", features: feats }); map.getSource("lines").__filled = true;
  map.getSource("stations").setData({ type: "FeatureCollection", features: [...E.stations.stations.values()].filter(s => s.lngLat).map(s => ({ type: "Feature", properties: { id: s.id, name: s.name }, geometry: { type: "Point", coordinates: s.lngLat } })) });
  emphasizeLine(); drawPath(); drawTrains(); drawIncidents(); applyLayerVisibility();
}
function emphasizeLine() {
  if (!mapReady) return;
  const sel = S.line;
  map.setPaintProperty("lines", "line-opacity", sel ? ["case", ["==", ["get", "base"], sel], 1, 0.16] : 0.9);
  map.setPaintProperty("lines", "line-width", sel ? ["interpolate", ["linear"], ["zoom"], 9, ["case", ["==", ["get", "base"], sel], 3.5, 1.4], 15, ["case", ["==", ["get", "base"], sel], 9, 4]]
    : ["interpolate", ["linear"], ["zoom"], 9, 1.6, 12, 3, 15, 6]);
}

// train positions: on the track, nudged to the right of the direction of travel so both directions show
const RAD = Math.PI / 180, COSLAT = Math.cos(40.7 * RAD);
function placed(L, idx) {
  const n = L.geo.n, p = L.geo.at(idx); let q = L.geo.at(Math.min(n - 1, idx + 0.04)), dx = q[0] - p[0], dy = q[1] - p[1];
  if (!dx && !dy) { q = L.geo.at(Math.max(0, idx - 0.04)); dx = p[0] - q[0]; dy = p[1] - q[1]; }
  const ux = dx * COSLAT, uy = dy, len = Math.hypot(ux, uy) || 1, off = 0.00016;
  return [p[0] + (uy / len) * off / COSLAT, p[1] - (ux / len) * off];
}
function trainFill(t, pal) {
  if (S.colorBy === "late") { if (t.kind === "scheduled" || t.late == null) return pal.na; return t.late >= 300 ? pal.crit : t.late >= 120 ? pal.warn : pal.good; }
  return routeColor(t.route);
}
function currentPositions() {
  if (S.replay != null) return E.positionsAt(S.replay).trains;
  const age = E.age();
  return E.trains.map(t => { const p = t.progress(age); return { id: t.id, key: t.key, route: t.route, dir: t.dir, idx: p.idx, state: p.state, late: t.late, kind: t.kind, track: t.track_changed, optimistic: t.corroboration === "feed_optimistic" }; });
}
function drawTrains() {
  if (!mapReady || !E || !E.trains) return;
  const pal = { good: cssVar("--status-good"), warn: cssVar("--status-warning"), crit: cssVar("--status-critical"), na: cssVar("--de-emphasis"), white: isDark() ? "#0e1116" : "#ffffff" };
  const feats = [];
  for (const t of currentPositions()) {
    const L = E.lines[t.key]; if (!L) continue;
    const sel = t.id === S.train, dim = S.line && baseRoute(t.route) !== S.line && !sel;
    const ring = t.state === "stalled" ? pal.crit : t.state === "holding" ? pal.warn : pal.white;
    const fill = trainFill(t, pal);
    feats.push({ type: "Feature", properties: { id: t.id, route: t.route, label: LABEL[t.route] || t.route, fill, ring, ringW: t.state === "stalled" || t.state === "holding" ? 2.5 : 1,
      ink: S.colorBy === "late" ? "#111" : (DARK_TEXT.has(baseRoute(t.route)) || t.route === "G" || t.route === "L" ? "#111" : "#fff"), sel, op: dim ? 0.18 : t.kind === "scheduled" ? 0.6 : 1 },
      geometry: { type: "Point", coordinates: placed(L, t.idx) } });
  }
  feats.sort((a, b) => a.properties.sel - b.properties.sel || a.properties.op - b.properties.op);
  map.getSource("trains").setData({ type: "FeatureCollection", features: feats });
}
let pulseT = 0;
function pulse() { pulseT = (pulseT + 1) % 8; if (map.getLayer("incident-pulse")) { map.setPaintProperty("incident-pulse", "circle-radius", 10 + pulseT * 2.2); map.setPaintProperty("incident-pulse", "circle-stroke-opacity", 0.9 - pulseT * 0.1); } }
function drawIncidents() {
  if (!mapReady || !E) return;
  const feats = [];
  for (const ev of E.events) { if (!ev.open) continue; const L = E.lines[ev.lineKey]; if (!L || ev.stopIdx == null) continue;
    feats.push({ type: "Feature", properties: { key: ev.key, severity: ev.severity }, geometry: { type: "Point", coordinates: L.geo.stop(ev.stopIdx) } }); }
  for (const pw of prewarnings()) { const seg = segmentCoords(pw.route, pw.direction, pw.from_stop, pw.to_stop); if (seg) feats.push({ type: "Feature", properties: { severity: "medium" }, geometry: { type: "LineString", coordinates: seg } }); }
  map.getSource("incidents").setData({ type: "FeatureCollection", features: feats });
}
function segmentCoords(route, dir, a, b) {
  const L = E.lines[`${route}_${dir}`]; if (!L) return null;
  const i = L.line.stops.indexOf(a), k = L.line.stops.indexOf(b); if (i < 0 || k < 0) return null;
  return L.geo.between(Math.min(i, k), Math.max(i, k));
}
function drawHotspots() {
  if (!mapReady) return;
  const feats = [];
  for (const s of (D.holds && D.holds.by_stop) || []) { const ll = stopLngLat.get(s.stop_id); if (ll) feats.push({ type: "Feature", properties: { kind: "hold", r: Math.min(26, 4 + Math.sqrt(s.per_day) * 2.2), name: s.name, text: `${s.per_day.toFixed(1)} holds a day, median ${Math.round(s.median_sec / 60)} min` }, geometry: { type: "Point", coordinates: ll } }); }
  for (const s of (D.dwell && D.dwell.stops) || []) { const ll = stopLngLat.get(s.stop_id); if (ll && s.median_sec >= 60) feats.push({ type: "Feature", properties: { kind: "dwell", r: Math.min(22, 3 + s.median_sec / 30), name: s.name, text: `median dwell ${Math.round(s.median_sec)} s (${s.n} stops observed)` }, geometry: { type: "Point", coordinates: ll } }); }
  map.getSource("hotspots").setData({ type: "FeatureCollection", features: feats });
}
function drawPath(features = currentPathFeatures) {
  currentPathFeatures = features;
  if (mapReady && map.getSource("path")) map.getSource("path").setData({ type: "FeatureCollection", features });
}
let currentPathFeatures = [];

function bindMapEvents() {
  const hover = new maplibregl.Popup({ closeButton: false, closeOnClick: false, offset: 12 });
  map.on("mousemove", "trains", e => {
    map.getCanvas().style.cursor = "pointer";
    const id = e.features[0].properties.id, t = E.trainById(id); if (!t) return;
    const L = E.lines[t.key];
    hover.setLngLat(e.features[0].geometry.coordinates).setHTML("").addTo(map);
    const box = h("div"); const top = h("div", "row", null, box); top.style.gap = "6px"; bullet(t.route, top, "sm"); h("b", null, `to ${L.terminus}`, top);
    h("div", null, t.kind === "scheduled" ? "scheduled position" : `${lateText(t.late)} · next ${t.next_name}`, box);
    hover.setDOMContent(box);
  });
  map.on("mouseleave", "trains", () => { map.getCanvas().style.cursor = ""; hover.remove(); });
  for (const id of ["stations", "hotspots", "lines"]) {
    map.on("mouseenter", id, () => { map.getCanvas().style.cursor = "pointer"; });
    map.on("mouseleave", id, () => { map.getCanvas().style.cursor = ""; hover.remove(); });
  }
  map.on("mousemove", "stations", e => { if (map.queryRenderedFeatures(e.point, { layers: ["trains"] }).length) return; hover.setLngLat(e.lngLat).setText(e.features[0].properties.name).addTo(map); });
  map.on("mousemove", "hotspots", e => { const p = e.features[0].properties; const b = h("div"); h("b", null, p.name, b); h("div", null, p.text, b); hover.setLngLat(e.lngLat).setDOMContent(b).addTo(map); });
  map.on("click", e => {
    const f = map.queryRenderedFeatures([[e.point.x - 6, e.point.y - 6], [e.point.x + 6, e.point.y + 6]], { layers: ["trains", "stations", "lines"].filter(l => map.getLayer(l) && map.getLayoutProperty(l, "visibility") !== "none") });
    const tr = f.find(x => x.layer.id === "trains"), st = f.find(x => x.layer.id === "stations"), ln = f.find(x => x.layer.id === "lines");
    if (tr) return selectTrain(tr.properties.id);
    if (st) {
      if (S.tab === "route" && (pickTarget === "from" || pickTarget === "to")) { setEndpoint(pickTarget, st.properties.id); return; }
      return selectStation(st.properties.id);
    }
    if (ln) return selectLine(ln.properties.base);
    if (S.train || S.station) { S.train = null; S.follow = false; S.station = null; writeHash(); renderInspector(); drawTrains(); }
  });
  map.on("dragstart", () => { if (S.follow) { S.follow = false; renderInspector(); } });
}

// ---------------------------------------------------------------- selection
function selectLine(route, { fit = true } = {}) {
  S.line = route; if (route) { const L = E.lines[`${route}_${S.dir}`] || E.lines[`${route}_N`] || E.lines[`${route}_S`]; if (L) S.dir = L.dir; }
  writeHash(); emphasizeLine(); drawTrains(); renderLeft(); toggleDock("left", true);
  if (route && fit && map) { const coords = Object.values(E.lines).filter(L => baseRoute(L.route) === route).flatMap(L => L.geo.full()); if (coords.length) map.fitBounds(bboxOf(coords), { padding: 60, duration: 700 }); }
}
function selectTrain(id, { fly = true } = {}) {
  S.train = id; S.station = null; S.follow = false; writeHash();
  const t = E.trainById(id); if (t && fly && map) { const L = E.lines[t.key]; map.easeTo({ center: placed(L, t.progress(E.age()).idx), zoom: Math.max(map.getZoom(), 13), duration: 700 }); }
  renderInspector(); drawTrains();
}
function followTrain() { const t = E.trainById(S.train); if (!t || !map) return; map.easeTo({ center: placed(E.lines[t.key], t.progress(E.age()).idx), duration: 900 }); }
function selectStation(id, fly = false) {
  S.station = id; S.train = null; S.follow = false; writeHash();
  const st = E.stations.stations.get(id); if (st && st.lngLat && fly && map) map.easeTo({ center: st.lngLat, zoom: Math.max(map.getZoom(), 14), duration: 700 });
  renderInspector(); drawTrains(); if (S.tab === "stations") renderRight();
}

// ---------------------------------------------------------------- inspector (over the map)
function renderInspector() {
  const box = $("#inspector"); box.replaceChildren();
  if (!E || (!S.train && !S.station)) { box.hidden = true; return; }
  box.hidden = false;
  const close = h("button", "insp-close", "×", box); close.setAttribute("aria-label", "Close"); close.addEventListener("click", () => { S.train = null; S.station = null; S.follow = false; writeHash(); renderInspector(); drawTrains(); });
  if (S.train) trainCard(box); else stationCard(box);
}
function trainCard(box) {
  const t = E.trainById(S.train);
  if (!t) { h("div", "empty-s", "This train has left the feed (it reached its terminal or went out of service).", box); return; }
  const L = E.lines[t.key], now = E.now(), p = t.progress(E.age());
  const head = h("div", "insp-head", null, box); bullet(t.route, head, "md");
  const ht = h("div", null, null, head); h("div", "t", `To ${L.terminus}`, ht);
  const state = t.kind === "scheduled" ? "Scheduled position (no live feed for this line)" : p.state === "holding" ? `Holding at ${t.position.stop_name} for ${mins(p.since)}`
    : p.state === "stalled" ? `Stalled before ${t.position.stop_name} for ${mins(p.since)}` : p.state === "stopped" || p.state === "terminal" ? `Stopped at ${t.position.stop_name}` : `Moving toward ${t.next_name}`;
  h("div", "s", `${state}${t.train_id ? ` · ${t.train_id}` : ""}`, ht);
  const s3 = h("div", "stat3", null, box);
  const cell = (l, v, cls) => { const d = h("div", null, null, s3); h("div", "l", l, d); h("div", `v ${cls || ""}`, v, d); };
  cell("vs schedule", t.kind === "scheduled" ? "–" : t.late == null ? "n/a" : Math.abs(t.late) < 45 ? "on time" : `${t.late > 0 ? "+" : "−"}${Math.round(Math.abs(t.late) / 60)} min`, lateClass(t.late));
  const lr = t.last_run; cell("Last run", lr && lr.speed_kmh ? `${Math.round(lr.speed_kmh)} km/h` : t.segment && t.segment.sched_speed_kmh ? `${Math.round(t.segment.sched_speed_kmh)} km/h sched` : "–");
  cell("Next stop", t.eta_ts ? `${Math.max(0, Math.round((t.eta_ts - now) / 60))} min` : "–");
  if (t.corroboration === "feed_optimistic") h("div", "note", "The MTA countdown is ahead of where this train actually is: expect it later than the countdown says.", box);
  if (t.track_changed) h("div", "note info", "Running on a different track than scheduled at the next stop.", box);
  h("div", "kicker", t.kind === "scheduled" ? "Scheduled stops ahead" : "Stops ahead (MTA countdown)", box);
  const sa = h("div", "stops-ahead", null, box);
  const pts = (t.points || []).filter(([, ts]) => ts >= now - 30);
  for (const [i, ts] of pts.slice(0, 6)) { const r = h("div", null, null, sa); h("span", null, L.line.names[i], r); h("span", "mono", hhmm(ts), r); }
  if (pts.length > 6) { const r = h("div", null, null, sa); h("span", "muted", `+ ${pts.length - 6} more to ${L.line.names[pts[pts.length - 1][0]]}`, r); h("span", "mono", hhmm(pts[pts.length - 1][1]), r); }
  if (!pts.length) h("div", "empty-s", "No predicted stops ahead.", box);
  const btns = h("div", "btn-row", null, box);
  const fb = h("button", `btn ${S.follow ? "primary" : ""}`, S.follow ? "Following" : "Follow", btns); fb.type = "button";
  fb.addEventListener("click", () => { S.follow = !S.follow; if (S.follow) followTrain(); renderInspector(); });
  const lb = h("button", "btn", `${LABEL[t.route] || t.route} line insights`, btns); lb.type = "button"; lb.addEventListener("click", () => { S.dir = t.dir; selectLine(baseRoute(t.route), { fit: false }); });
}
function stationBoard(st, now, maxN = 12) {
  const out = [];
  for (const m of st.members) {
    const L = E.lines[m.key]; if (!L || !L.board) continue;
    for (const t of L.board.trains) { const pt = (t.points || []).find(p => p[0] === m.idx); if (!pt || pt[1] < now - 30 || pt[1] > now + 3600) continue;
      out.push({ t, L, m, ts: pt[1], key: m.key, id: `${m.key}|${t.trip_id}` }); }
  }
  out.sort((a, b) => a.ts - b.ts);
  // a gap: the wait for this train since the previous one of the same line and direction is over twice the schedule
  const last = new Map();
  for (const d of out) { const prev = last.get(d.key); if (prev != null && d.L.hw) d.gap = d.ts - prev > Math.max(2 * d.L.hw, 600); last.set(d.key, d.ts); }
  return out.slice(0, maxN);
}
function departureRows(list, parent, now, compact = false) {
  if (!list.length) { h("div", "empty-s", "No trains due in the next hour.", parent); return; }
  for (const d of list) {
    const row = h("div", `dep${d.gap ? " gap" : ""}`, null, parent); row.style.cursor = "pointer";
    h("span", "min", String(Math.max(0, Math.round((d.ts - now) / 60))), row);
    bullet(d.t.route, row, "sm");
    const to = h("span", "to", d.L.terminus, row);
    const late = d.t.effective_lateness_sec ?? d.t.lateness_sec;
    h("span", `sub ${d.gap ? "" : lateClass(late)}`, d.gap ? `${Math.round(d.L.hw / 60)}-min service, long gap before this train` : d.L.mode === "scheduled" ? "scheduled" : d.t.position && d.t.position.holding ? `holding · ${lateText(late)}` : lateText(late), to);
    if (!compact) h("span", "rng", hhmm(d.ts), row); else h("span", "rng", "", row);
    row.addEventListener("click", () => selectTrain(d.id));
  }
}
function stationCard(box) {
  const st = E.stations.stations.get(S.station); if (!st) { box.hidden = true; return; }
  const now = E.now();
  const head = h("div", "insp-head", null, box);
  const ht = h("div", null, null, head); h("div", "t", st.name, ht);
  const br = h("div", "row", null, ht); br.style.gap = "4px"; br.style.marginTop = "6px"; for (const r of st.routes.filter(r => !/X$/.test(r))) bullet(r, br, "sm");
  h("div", "kicker", "Next trains", box).style.marginTop = "12px";
  departureRows(stationBoard(st, now, 6), box, now, true);
  const btns = h("div", "btn-row", null, box); btns.style.marginTop = "12px";
  const b1 = h("button", "btn primary", "Full board", btns); b1.type = "button"; b1.addEventListener("click", () => setTab("stations"));
  const b2 = h("button", "btn", "From here", btns); b2.type = "button"; b2.addEventListener("click", () => { setEndpoint("from", st.id); setTab("route"); });
  const b3 = h("button", "btn", "To here", btns); b3.type = "button"; b3.addEventListener("click", () => { setEndpoint("to", st.id); setTab("route"); });
}

// ---------------------------------------------------------------- left: lines
function renderLeft() {
  const body = $("#left-body"); if (!E || !E.trains) return;
  const keep = body.scrollTop; body.replaceChildren();
  $("#left-back").hidden = !S.line; $("#left-title").textContent = S.line ? "" : "Lines";
  if (S.line) lineDetail(body); else lineList(body);
  if (lineListScroll.line === S.line) body.scrollTop = keep; lineListScroll.line = S.line;
}
const lineListScroll = { line: undefined };
function lineList(body) {
  const hs = [...health.values()];
  const sum = h("p", "lede", null, body); sum.style.marginTop = "0";
  const n = st => hs.filter(x => x.status === st).length;
  sum.textContent = hs.some(x => x.live) ? `${n("good")} lines running well, ${n("degraded")} with delays, ${n("disrupted")} disrupted. Click a line for its live trains and history.`
    : "Live feeds are not available: trains are drawn where today's schedule puts them.";
  const sorts = h("div", "chips-row", null, body);
  for (const [k, lab] of [["map", "Network order"], ["worst", "Worst first"]]) { const c = h("button", `chip${S.lineSort === k ? " on" : ""}`, lab, sorts); c.type = "button"; c.addEventListener("click", () => { S.lineSort = k; renderLeft(); }); }
  const list = h("div", "line-grid", null, body);
  const routes = hs.sort((a, b) => S.lineSort === "worst" ? b.score - a.score : routeSort(a.route, b.route));
  for (const x of routes) {
    const row = h("button", "line-row", null, list); row.type = "button";
    bullet(x.route, row, "md");
    const mid = h("div", null, null, row); h("div", "n", LINE_NAMES[x.route] || x.route, mid);
    const bits = [`${x.trains} trains`];
    if (x.median_late != null) bits.push(Math.abs(x.median_late) < 45 ? "on time" : `median ${lateText(x.median_late)}`);
    if (x.holding) bits.push(`${x.holding} holding`); if (x.stalled) bits.push(`${x.stalled} stalled`); if (x.gaps) bits.push(`${x.gaps} gap${x.gaps > 1 ? "s" : ""}`);
    h("div", "d", bits.join(" · "), mid);
    const pill = h("span", `st-pill st-${x.status}`, null, row); h("span", "dot", null, pill);
    pill.appendChild(document.createTextNode({ good: "Good", degraded: "Delays", disrupted: "Disrupted", scheduled: "Scheduled" }[x.status]));
    row.addEventListener("click", () => selectLine(x.route));
  }
}
const lineCache = new Map();
function lineFile(key) { if (!lineCache.has(key)) lineCache.set(key, load(`lines/${key}.json`).then(v => { renderLeftSoon(); return v; })); return lineCache.get(key); }
let leftTimer = null; const renderLeftSoon = () => { clearTimeout(leftTimer); leftTimer = setTimeout(renderLeft, 50); };
const resolved = new Map(); function settled(p, key) { p.then(v => resolved.set(key, v)); return resolved.get(key); }

function lineDetail(body) {
  const r = S.line, x = health.get(r) || { trains: 0, byDir: {}, alerts: [] };
  const keys = Object.keys(E.lines).filter(k => baseRoute(E.lines[k].route) === r);
  if (!E.lines[`${r}_${S.dir}`]) S.dir = keys.length ? E.lines[keys[0]].dir : "N";
  const key = `${r}_${S.dir}`, L = E.lines[key], now = E.now();
  const head = h("div", "insp-head", null, body); bullet(r, head, "lg");
  const ht = h("div", null, null, head); h("div", "t", `${LABEL[r] || r} · ${LINE_NAMES[r] || ""}`, ht).style.fontSize = "20px";
  if (L) h("div", "s", `${L.origin} ↔ ${L.terminus} · ${x.trains} trains running`, ht);
  const dirs = h("div", "dirs", null, body);
  for (const k of keys.filter(k => !/X_/.test(k)).sort()) { const LL = E.lines[k]; const b = h("button", LL.dir === S.dir ? "on" : "", `To ${LL.terminus}`, dirs); b.type = "button"; b.addEventListener("click", () => { S.dir = LL.dir; writeHash(); renderLeft(); }); }
  if (!L) return;

  // headline: the line's reliability over the last weeks
  const sc = ((D.scorecard && D.scorecard.rows) || []).find(row => row.route === r && row.direction === S.dir);
  if (sc) {
    h("div", "big-stat", pct(sc.share_late_5min), body);
    h("p", "lede", `of stop arrivals were 5 or more minutes late over the last ${Math.round((D.scorecard.days || 28))} days. Riders lose ${(sc.loss_per_trip_sec / 60).toFixed(1)} min per trip; worst at ${sc.worst_segment_stop}.`, body);
  }

  // live now
  const sec = h("div", "section", null, body); h("span", "kicker", L.mode === "live" ? "Live now" : "Now (scheduled positions)", sec);
  const trains = E.trains.filter(t => t.key === key || t.key === `${r}X_${S.dir}`);
  const s2 = h("div", "stat2", null, sec);
  const cell = (l, v, cls) => { const d = h("div", null, null, s2); h("div", "l", l, d); h("div", `v ${cls || ""}`, v, d); };
  const lat = trains.map(t => t.late).filter(v => v != null).sort((a, b) => a - b), med = lat.length ? lat[Math.floor(lat.length / 2)] : null;
  cell("Trains this direction", String(trains.length));
  cell("Median vs schedule", med == null ? "–" : lateText(med), lateClass(med));
  cell("Holding / stalled", `${trains.filter(t => t.position && t.position.holding).length} / ${trains.filter(t => t.position && t.position.stalled).length}`);
  cell("Scheduled every", L.hw ? `${Math.round(L.hw / 60)} min` : "–");
  for (const a of x.alerts || []) { const n = h("div", "note", null, sec); richText(a.header, n); }
  for (const ev of E.events.filter(ev => ev.open && ev.lineKey === key)) { const n = h("div", "note", null, sec); h("b", null, ev.title, n); n.appendChild(document.createTextNode(` · ${ev.text}`)); }

  // stringline
  const sl = h("div", "section", null, body); h("span", "kicker", "Every train on the line, next 60 minutes", sl);
  const stops = L.line.names.map(name => ({ name }));
  const legTrains = L.board ? L.board.trains.map(t => ({ trip_id: `${key}|${t.trip_id}`, route_id: t.route, points: t.points, lateness_sec: t.late ?? t.lateness_sec, kind: L.mode === "scheduled" ? "sched" : "feed" })) : [];
  const actual = settled(lineFile(key), key);
  if (actual && actual.snapshot && actual.snapshot.actual && now - actual.snapshot.now < 5400)
    for (const a of actual.snapshot.actual) legTrains.push({ trip_id: a.trip_id, route_id: r, points: a.points, lateness_sec: a.last_lateness, kind: "actual" });
  stringline(sl, { legs: [{ stops, trains: legTrains }], now, horizonSec: 3600, backSec: 900, rowH: 16, routeColor: rr => routeColor(rr), highlight: new Set(S.train ? [S.train] : []) });
  h("div", "small-print", "Lines are trains (stops down, time across). Steeper is faster; flat stretches are trains held at a stop. Click a train below or on the map to follow it.", sl);
  const tl = h("div", "train-list", null, sl);
  for (const t of trains.sort((a, b) => b.progress(0).idx - a.progress(0).idx).slice(0, 30)) {
    const b = h("button", null, null, tl); b.type = "button";
    const l = h("div", null, null, b); h("div", null, `${t.kind === "scheduled" ? "Near" : t.position && t.position.status === "STOPPED_AT" ? "At" : "Toward"} ${t.kind === "scheduled" ? L.line.names[Math.round(t.sched_idx)] : t.position ? t.position.stop_name : t.next_name}`, l);
    h("div", "sub", t.train_id || t.trip_id, l);
    h("div", lateClass(t.late), t.kind === "scheduled" ? "scheduled" : (t.position && t.position.holding ? "holding · " : t.position && t.position.stalled ? "stalled · " : "") + lateText(t.late), b);
    b.addEventListener("click", () => selectTrain(t.id));
  }

  // where time is lost: lateness change by stop and hour
  if (actual && actual.deviation && actual.deviation.grid) {
    const dv = actual.deviation, s = h("div", "section", null, body); h("span", "kicker", "Where trains lose time", s);
    if (dv.worst_stops && dv.worst_stops.length) h("p", "lede", `Biggest average loss: ${dv.worst_stops.slice(0, 3).map(w => `${w.name} (+${Math.round(w.mean_delta_sec)} s)`).join(", ")}. From ${fmt.num(dv.n_trips)} trips.`, s);
    const hours = Array.from({ length: 24 }, (_, i) => String(i).padStart(2, "0"));
    heatmap(s, { title: "Lateness gained at each stop, by hour", subtitle: "seconds added between the previous stop and this one (more blue is worse)", rows: dv.stops.map(st => st.name.length > 16 ? st.name.slice(0, 15) + "…" : st.name), cols: hours,
      values: dv.grid.map(row => row.map(v => v == null ? null : Math.max(0, v))), format: v => `${Math.round(v)} s`, colLabelEvery: 3 });
  } else if (!actual) { const s = h("div", "section", null, body); h("span", "kicker", "Where trains lose time", s); h("div", "empty-s", "Loading the line's history…", s); }

  // reliability table
  if (sc) {
    const s = h("div", "section", null, body); h("span", "kicker", "Reliability, this direction", s);
    const kv = (k, v) => { const d = h("div", "kv", null, s); h("span", null, k, d); h("span", "mono", v, d); };
    kv("Mean lateness", `${(sc.mean_lateness_sec / 60).toFixed(1)} min`); kv("90th percentile", `${(sc.p90_lateness_sec / 60).toFixed(1)} min`);
    kv("Trips that lost 3+ min", pct(sc.share_trips_grew_3min)); kv("Early arrivals", pct(sc.share_early));
    kv("Headway variation, peak / off-peak", `${sc.headway_cv_peak.toFixed(2)} / ${sc.headway_cv_offpeak.toFixed(2)}`); kv("Busiest stop", sc.busiest_stop); kv("Trips per day", fmt.num(sc.trips_per_day));
  }
  // holds and dwell
  const hr = ((D.holds && D.holds.by_route) || []).find(x2 => x2.route === r);
  const dw = ((D.dwell && D.dwell.stops) || []).filter(s => (s.routes || []).includes(r)).sort((a, b) => b.median_sec - a.median_sec).slice(0, 5);
  if (hr || dw.length) {
    const s = h("div", "section", null, body); h("span", "kicker", "Holds and long dwells", s);
    if (hr) h("p", "lede", `${hr.per_day.toFixed(0)} holds a day (trains stopped 2.5+ min), median ${Math.round(hr.median_sec / 60)} min, ${Math.round(hr.total_min_per_day)} train-minutes lost daily.`, s);
    for (const d of dw) { const row = h("div", "kv", null, s); const a = h("a", null, d.name, row); a.href = "#"; a.addEventListener("click", ev => { ev.preventDefault(); const ll = stopLngLat.get(d.stop_id); if (ll) map.easeTo({ center: ll, zoom: 14.5 }); }); h("span", "mono", `${Math.round(d.median_sec)} s median dwell`, row); }
  }
  // disruptions
  const cl = ((D.climatology && D.climatology.by_route) || []).find(x2 => x2.route === r);
  if (cl) {
    const s = h("div", "section", null, body); h("span", "kicker", "Disruptions (MTA alert archive)", s);
    h("p", "lede", `${cl.per_week.toFixed(1)} unplanned disruptions a week; half clear within ${Math.round(cl.median_duration_min)} min, 1 in 10 lasts over ${Math.round(cl.p90_duration_min)} min.`, s);
    const g = D.climatology.grid_by_route && D.climatology.grid_by_route[r];
    if (g) heatmap(s, { title: "When they happen", subtitle: "share of weeks with a disruption starting in that hour", rows: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], cols: Array.from({ length: 24 }, (_, i) => String(i)), values: g, format: fmt.pct, colLabelEvery: 3 });
  }
  const ln = D.lines && D.lines.lines && D.lines.lines[r];
  if (ln && ln.monthly_total) {
    const s = h("div", "section", null, body); h("span", "kicker", "Delays reported by the MTA, monthly", s);
    lineChart(s, { title: `${fmt.num(ln.latest_total)} delays last month`, subtitle: `${ln.yoy_change != null ? `${ln.yoy_change > 0 ? "+" : ""}${Math.round(ln.yoy_change * 100)}% vs a year ago · ` : ""}top cause over-indexed: ${((ln.category_mix_3m || []).slice().sort((a, b) => b.over_index - a.over_index)[0] || {}).category || "–"}`,
      x: D.lines.months, series: [{ name: "Delays", values: ln.monthly_total }], height: 180, labelEvery: 6 });
  }
  const et = D.eta_trust && D.eta_trust.by_route && (D.eta_trust.by_route[r] || D.eta_trust.by_route[`${r}X`]);
  const tr = ((D.train_runs && D.train_runs.by_route) || []).find(x2 => x2.route === r);
  if (et || tr) {
    const s = h("div", "section", null, body); h("span", "kicker", "Countdown clocks and terminals", s);
    if (et) for (const row of et.slice(0, 4)) { const d = h("div", "kv", null, s); h("span", null, `${row.stops_ahead} stop${row.stops_ahead > 1 ? "s" : ""} away`, d); h("span", "mono", `±${Math.round(row.median_abs_err_sec)} s typical, ${row.bias_sec > 0 ? "+" : ""}${Math.round(row.bias_sec)} s bias`, d); }
    if (tr) h("p", "lede", `At the terminals, ${pct(tr.share_late_in)} of trains arrive 5+ min late and ${pct(tr.share_late_out_given_late_in)} of those leave late again (median layover ${Math.round(tr.median_layover_min)} min).`, s);
  }
  const more = h("p", "small-print", null, body); const a = h("a", null, "Open the classic line view →", more); a.href = `../#/line/${key}`;
}

// ---------------------------------------------------------------- right panel
let routeFormBuilt = false;
function renderRight() {
  if (!E || !E.trains) return;
  const body = $("#right-body");
  if (S.tab === "route") { renderRoute(body); return; }
  const keep = body.scrollTop; body.replaceChildren();
  ({ feed: renderFeed, stations: renderStations, system: renderSystem }[S.tab] || renderFeed)(body);
  body.scrollTop = keep;
}
function liveAlerts() {
  if (E && E.alerts) return E.alerts;
  return ((D.alerts && D.alerts.alerts) || []).filter(a => a.active_now).map(a => ({ id: a.alert_id, type: a.alert_type, kind: a.kind, header: a.header, routes: a.routes, start: a.active_start, snapshot: true }));
}
function prewarnings() { const pw = (D.alerts && D.alerts.prewarnings) || []; const now = E ? E.now() : Date.now() / 1000; return pw.filter(p => now - p.onset_ts < 3 * 3600); }

function feedItems() {
  const now = E.now(), items = [];
  for (const ev of E.events) items.push({ cat: "live", ts: ev.first_ts, open: ev.open, route: ev.route, title: ev.title, text: ev.open ? ev.text : `${ev.text} · cleared ${ago(ev.ended_ts, now)}`,
    meta: ev.open ? `Live · ${ago(ev.first_ts, now)}` : "Cleared", metaCls: ev.open ? "live" : "", go: () => { if (ev.trainId && E.trainById(ev.trainId)) selectTrain(ev.trainId); else { S.dir = ev.lineKey.split("_")[1]; selectLine(baseRoute(ev.route)); } } });
  for (const p of prewarnings()) items.push({ cat: "live", ts: p.onset_ts, open: true, route: p.route, title: `Slowdown building on the ${p.route}, ahead of any MTA alert`,
    text: `${p.where}: ${p.n_slow} of ${p.n_trains} trains slow, ${p.loss_sec} s lost. ${pct(p.p_alert_60)} chance of an alert within the hour.`, meta: `Early warning · as of ${hhmm(D.alerts.generated_at ? Date.parse(D.alerts.generated_at) / 1000 : p.onset_ts)}`, metaCls: "warn",
    go: () => { const seg = segmentCoords(p.route, p.direction, p.from_stop, p.to_stop); if (seg) map.fitBounds(bboxOf(seg), { padding: 120, maxZoom: 15 }); S.dir = p.direction; selectLine(baseRoute(p.route), { fit: false }); } });
  for (const a of liveAlerts()) items.push({ cat: "alerts", ts: a.start || a.updated || 0, open: true, route: (a.routes || [])[0], header: a.header, title: null, text: null,
    meta: `MTA ${a.kind === "planned" ? "planned work" : a.kind === "notice" ? "notice" : "alert"}${a.type ? ` · ${a.type}` : ""}`, metaCls: a.kind === "delay" ? "live" : "", rank: a.kind === "delay" ? 0 : a.kind === "planned" ? 1 : 2,
    go: () => { const rr = (a.routes || []).map(baseRoute).find(x => health.has(x)); if (rr) selectLine(rr); } });
  if (D.live && D.live.stations && now - D.live.generated_ts < 5400) for (const st of D.live.stations) for (const ef of st.effects || [])
    items.push({ cat: "live", ts: D.live.generated_ts, open: true, route: ef.route_id, title: st.label, text: ef.text, meta: `Platform forecast · as of ${hhmm(D.live.generated_ts)}`, metaCls: "warn",
      go: () => { const sid = E.stations.stationOf(st.stop_id); selectStation(sid, true); } });
  for (const it of (D.digest && D.digest.items) || []) {
    const m = /^\*\*([A-Z0-9]+) (north|south)bound\*\*/i.exec(it.text);
    items.push({ cat: "research", ts: 0, open: true, route: m ? m[1] : null, header: it.text, meta: `Research · ${it.kind.replace(/_/g, " ")}`, metaCls: "research",
      go: m ? () => { S.dir = m[2].toLowerCase() === "north" ? "N" : "S"; selectLine(baseRoute(m[1])); } : it.kind === "route" ? () => setTab("route") : () => setTab("system") });
  }
  return items;
}
function renderFeed(body) {
  const all = feedItems();
  const counts = { all: all.length, live: all.filter(i => i.cat === "live" && i.open).length, alerts: all.filter(i => i.cat === "alerts").length, research: all.filter(i => i.cat === "research").length };
  const chips = h("div", "chips-row", null, body);
  for (const [k, lab] of [["all", "All"], ["live", "Live"], ["alerts", "MTA alerts"], ["research", "Research"]]) {
    const c = h("button", `chip${S.feed === k ? " on" : ""}`, lab, chips); c.type = "button"; h("span", "c", String(counts[k]), c);
    c.addEventListener("click", () => { S.feed = k; renderRight(); });
  }
  const order = { live: 0, alerts: 1, research: 2 };
  const shown = all.filter(i => S.feed === "all" || i.cat === S.feed).sort((a, b) => (b.open - a.open) || order[a.cat] - order[b.cat] || (a.rank || 0) - (b.rank || 0) || b.ts - a.ts);
  if (!shown.length) h("div", "empty-s", S.feed === "live" ? "Nothing unusual right now: no held, stalled or gapped trains across the network." : "Nothing here yet.", body);
  const list = h("div", "feed", null, body);
  for (const it of shown.slice(0, 120)) {
    const b = h("button", `feed-item${it.open ? "" : " closed"}`, null, list); b.type = "button";
    if (it.route && routeColor(it.route) !== "#6b6b6b") bullet(it.route, b, "sm"); else h("span", "icon", it.cat === "research" ? "∑" : "!", b);
    const c = h("div", null, null, b);
    if (it.title) h("div", "t", it.title, c);
    if (it.header) richText(it.header, h("div", it.title ? "x" : "t", null, c));
    if (it.text) h("div", "x", it.text, c);
    h("div", `m ${it.metaCls || ""}`, it.meta, c);
    b.addEventListener("click", it.go);
  }
  h("p", "small-print", "Live items are detected in your browser from the MTA feeds every 30 seconds: trains held at a stop 2.5+ min, trains stuck between stops, gaps over twice the scheduled headway, and track changes. Research items come from the daily analysis.", body);
}

// ---- route planner
let pickTarget = null;
function setEndpoint(which, id) { S[which] = id; S.opt = 0; pickTarget = which === "from" && !S.to ? "to" : null; writeHash(); routeFormBuilt = false; renderRight(); }
function stationLabel(id) { const st = E.stations.stations.get(id); return st ? st.name : ""; }
function renderRoute(body) {
  if (!routeFormBuilt) {
    body.replaceChildren(); routeFormBuilt = true;
    const form = h("div", "route-form", null, body);
    for (const which of ["from", "to"]) {
      const lab = h("label", null, which === "from" ? "From" : "To", form);
      const cb = h("div", "combo", null, lab); const inp = h("input", "combo-input", null, cb); inp.type = "search"; inp.placeholder = which === "from" ? "Starting station" : "Destination"; inp.value = S[which] ? stationLabel(S[which]) : "";
      const ul = h("ul", "combo-list", null, cb); ul.hidden = true;
      combo(inp, ul, () => searchItems().filter(i => i.kind === "station"), it => setEndpoint(which, it.value));
      inp.addEventListener("focus", () => { pickTarget = which; });
    }
    const tools = h("div", "route-tools", null, form);
    const sw = h("button", "btn", "⇅ Swap", tools); sw.type = "button"; sw.style.flex = "none";
    sw.addEventListener("click", () => { [S.from, S.to] = [S.to, S.from]; S.opt = 0; writeHash(); routeFormBuilt = false; renderRight(); });
    h("span", null, "or click stations on the map", tools);
    h("div", "route-results", null, body);
  }
  const res = body.querySelector(".route-results"); res.replaceChildren();
  if (!(S.from && S.to)) { drawPath([]); commutes(res); return; }
  const now = E.now();
  const opts = enumeratePaths(E.schedule, E.stations, S.from, S.to, 6);
  if (!opts.length) { h("div", "empty-s", "No route with at most one change between these stations.", res); drawPath([]); return; }
  const boards = Object.fromEntries(Object.values(E.lines).map(L => [L.key, L.board]));
  const ranked = opts.map(o => ({ o, its: pathTrips(boards, E.schedule, o, now, 3) })).sort((a, b) => ((a.its[0] || {}).arrive_ts ?? now + a.o.sched_sec + 1e6) - ((b.its[0] || {}).arrive_ts ?? now + b.o.sched_sec + 1e6));
  if (S.opt >= ranked.length) S.opt = 0;
  ranked.forEach(({ o, its }, i) => {
    const card = h("button", `opt${i === S.opt ? " sel" : ""}`, null, res); card.type = "button";
    const best = its[0];
    const top = h("div", "top", null, card);
    h("div", "big", best ? `${Math.round(best.total_sec / 60)} min` : `~${Math.round(o.sched_sec / 60)} min`, top);
    h("div", "rng", best ? `leave in ${Math.max(0, Math.round((best.board_ts - now) / 60))} min · arrive ${hhmm(best.arrive_ts)}` : "no live train found: scheduled time", top);
    const legs = h("div", "legs", null, card);
    o.legs.forEach((lg, li) => { if (li) h("span", null, `→ at ${o.transfer.station} →`, legs); for (const r of lg.routes.filter((v, k, a) => a.indexOf(v) === k)) bullet(r, legs, "sm"); });
    if (best) {
      const bar = h("div", "legbar", null, card), tot = Math.max(1, best.arrive_ts - now);
      const seg = (sec, color) => { const s = h("span", null, null, bar); s.style.flex = String(Math.max(0, sec) / tot); s.style.background = color; };
      seg(best.board_ts - now, cssVar("--grid"));
      best.legs.forEach((l, li) => { if (li) seg(best.legs[li].board_ts - best.legs[li - 1].arrive_ts, cssVar("--grid")); seg(l.arrive_ts - l.board_ts, routeColor(l.route)); });
      if (its.length > 1) h("div", "deps", `Then ${its.slice(1).map(x => `leave ${hhmm(x.board_ts)}, arrive ${hhmm(x.arrive_ts)}`).join(" · ")}`, card);
      if (best.connection_margin_sec != null) h("div", best.connection_margin_sec < 60 ? "warn-line" : "deps", `${best.connection_margin_sec < 60 ? "Tight connection" : "Connection"}: ${Math.round(best.connection_margin_sec)} s to spare ${best.walk_sec ? `after the ${Math.round(best.walk_sec / 60)} min walk` : "across the platform"}${best.next_if_missed_sec ? `; next one ${Math.round(best.next_if_missed_sec / 60)} min later` : ""}`, card);
    }
    // what could go wrong on this option
    const keys = o.legs.flatMap(l => l.keys), why = [];
    const bad = E.trains.filter(t => keys.includes(t.key) && t.position && (t.position.holding || t.position.stalled));
    if (bad.length) why.push(`${bad.length} train${bad.length > 1 ? "s" : ""} held or stalled on these lines now`);
    const rts = [...new Set(o.legs.flatMap(l => l.routes.map(baseRoute)))];
    for (const a of liveAlerts().filter(a => a.kind === "delay" && (a.routes || []).some(rr => rts.includes(baseRoute(rr))))) why.push(`MTA alert: ${a.header}`);
    const scs = ((D.scorecard && D.scorecard.rows) || []).filter(row => o.legs.some(l => l.keys.includes(`${row.route}_${row.direction}`)));
    if (scs.length) { const w = scs.sort((a, b) => b.share_late_5min - a.share_late_5min)[0]; why.push(`Reliability: ${pct(w.share_late_5min)} of ${w.route} stop arrivals this direction run 5+ min late`); }
    for (const w of why) richText(w, h("div", w.startsWith("Reliability") ? "why" : "warn-line", null, card));
    card.addEventListener("click", () => { S.opt = i; renderRight(); });
    if (i === S.opt) showOption(o, best);
  });
  h("p", "small-print", "Options use every live train's own predicted times at your stops (or today's schedule where a feed is down), the scheduled transfer walk, and the reliability history of each line.", res);
}
function showOption(o, best) {
  const feats = [];
  o.legs.forEach((lg, li) => { const k = lg.keys[0], L = E.lines[k], [a, b] = lg.idx[k]; if (L) feats.push({ type: "Feature", properties: { color: routeColor(lg.routes[0]) }, geometry: { type: "LineString", coordinates: L.geo.between(a, b) } }); });
  const sig = o.id + "|" + S.from + "|" + S.to;
  drawPath(feats);
  if (showOption.last !== sig && feats.length && map) { map.fitBounds(bboxOf(feats.flatMap(f => f.geometry.coordinates)), { padding: { top: 80, bottom: 140, left: 60, right: 60 }, maxZoom: 14.5, duration: 700 }); showOption.last = sig; }
  if (best && best.legs[0] && !S.train) { /* highlight nothing by default: the path shows the way */ }
}
function commutes(res) {
  h("div", "empty-s", "Pick two stations to compare every way between them, ranked by live arrival time.", res);
  const js = (D.live && D.live.journeys) || (D.index && D.index.journeys) || [];
  if (!js.length) return;
  h("span", "kicker", "Studied commutes", res);
  for (const j of js) {
    const b = h("button", "target-row", null, res); b.type = "button";
    h("div", "t", j.label, b);
    const rf = ((D.routes && D.routes.routes) || []).find(x => x.id === j.id);
    h("div", "x", [j.best && j.best.summary, rf && rf.decomposition && rf.decomposition.dominant ? `Most variable part: ${rf.decomposition.dominant}` : null].filter(Boolean).join(" · ") || "", b);
    b.addEventListener("click", () => { const lg = j.legs; S.from = E.stations.stationOf(lg[0].from_stop); S.to = E.stations.stationOf(lg[lg.length - 1].to_stop); S.opt = 0; writeHash(); routeFormBuilt = false; renderRight(); });
  }
}

// ---- stations
function renderStations(body) {
  const now = E.now();
  if (S.station) {
    const st = E.stations.stations.get(S.station);
    if (st) {
      const back = h("button", "link-btn", "‹ Monitored platforms", body); back.type = "button"; back.addEventListener("click", () => { S.station = null; writeHash(); renderInspector(); renderRight(); });
      h("div", "t", st.name, body).style.cssText = "font-size:22px;font-weight:600;margin-top:8px";
      const br = h("div", "row", null, body); br.style.gap = "4px"; for (const r of st.routes.filter(r => !/X$/.test(r))) bullet(r, br);
      const board = stationBoard(st, now, 40);
      const dirs = [...new Set(st.members.map(m => m.dir))];
      for (const dir of dirs) {
        const list = board.filter(d => d.m.dir === dir).slice(0, 8);
        const terms = [...new Set(st.members.filter(m => m.dir === dir).map(m => E.lines[m.key] && E.lines[m.key].terminus).filter(Boolean))];
        h("div", "kicker", dir === "N" ? `Northbound / uptown${terms.length ? ` · to ${terms.slice(0, 3).join(", ")}` : ""}` : `Southbound / downtown${terms.length ? ` · to ${terms.slice(0, 3).join(", ")}` : ""}`, body).style.marginTop = "16px";
        departureRows(list, body, now);
      }
      const tgts = ((D.index && D.index.targets) || []).filter(t => st.members.some(m => (D.live && D.live.stations || []).find(x => x.id === t.id && x.stop_id === m.stop)));
      for (const t of tgts) {
        const s = h("div", "section", null, body); h("span", "kicker", `Diagnosis · ${t.label}`, s);
        if (t.verdict) h("p", "lede", t.verdict, s);
        if (t.top_cause) h("div", "kv", null, s).append(h("span", null, "Top cause"), h("span", null, (t.top_cause.cause || "").replace(/_/g, " ")));
        if (t.top_location) h("div", "kv", null, s).append(h("span", null, "Where it starts"), h("span", null, (t.top_location.cause || "").replace(/_/g, " ")));
        const a = h("a", null, "Full diagnosis report →", h("p", "small-print", null, s)); a.href = `../#/station/${t.id}`;
      }
      const stopIds = new Set(st.members.map(m => m.stop));
      const dw = ((D.dwell && D.dwell.stops) || []).filter(s => stopIds.has(s.stop_id)), hs = ((D.holds && D.holds.by_stop) || []).filter(s => stopIds.has(s.stop_id));
      if (dw.length || hs.length) {
        const s = h("div", "section", null, body); h("span", "kicker", "Dwell and holds here", s);
        for (const d of dw) { const k = h("div", "kv", null, s); h("span", null, `Median dwell (${d.stop_id.endsWith("N") ? "north" : "south"}bound)`, k); h("span", "mono", `${Math.round(d.median_sec)} s, ${pct(d.share_over_90s)} over 90 s`, k); }
        for (const d of hs) { const k = h("div", "kv", null, s); h("span", null, "Holds", k); h("span", "mono", `${d.per_day.toFixed(1)} a day`, k); }
      }
      return;
    }
  }
  h("p", "lede", "Click any station on the map or search for it to see its live departures. These platforms are monitored in depth:", body).style.marginTop = "0";
  const lv = (D.live && D.live.stations) || [];
  for (const t of (D.index && D.index.targets) || []) {
    const b = h("button", "target-row", null, body); b.type = "button";
    const top = h("div", "row", null, b); top.style.gap = "5px"; for (const r of (t.routes || []).filter(r => !/X$/.test(r))) bullet(r, top, "sm"); h("span", "t", t.label, top);
    const sev = t.severity || {}; h("div", "x", [sev.label ? `Severity: ${sev.label}` : null, t.verdict].filter(Boolean).join(" · "), b);
    const live = lv.find(x => x.id === t.id);
    b.addEventListener("click", () => { if (live) selectStation(E.stations.stationOf(live.stop_id), true); });
  }
}

// ---- system
function renderSystem(body) {
  const ix = D.index || {}, stt = D.status || {}, lm = ix.learned_model || {};
  const s2 = h("div", "stat2", null, body);
  const cell = (l, v) => { const d = h("div", null, null, s2); h("div", "l", l, d); h("div", "v", v, d); };
  cell("Arrivals analysed", fmt.compact(((stt.datasets || {}).network_arrivals || 0) + ((stt.datasets || {}).core_arrivals || 0)));
  cell("Days of history", String(stt.days_with_data || "–"));
  cell("Holds a day", D.holds ? fmt.num(D.holds.per_day) : "–");
  cell("Disruptions a week", D.climatology ? fmt.num(D.climatology.n_events / D.climatology.weeks) : "–");
  if (lm.status === "ok") {
    const s = h("div", "section", null, body); h("span", "kicker", "Arrival model", s);
    h("p", "lede", `Mean error ${Math.round(lm.mae_model)} s, against ${Math.round(lm.mae_schedule)} s for the timetable and ${Math.round(lm.mae_feed)} s for the MTA countdown. Trained on ${fmt.compact(lm.n_train)} arrivals.`, s);
    barChart(s, { title: "Mean error in seconds (lower is better)", categories: ["Timetable", "MTA clock", "Whichway"], series: [{ name: "error", values: [lm.mae_schedule, lm.mae_feed, lm.mae_model] }], height: 170, format: v => `${Math.round(v)} s` });
  }
  const cl = D.climatology;
  if (cl) {
    const s = h("div", "section", null, body); h("span", "kicker", "Disruptions in the alert archive", s);
    barChart(s, { title: "By hour of day", subtitle: "average events a week starting in each hour", categories: cl.per_week_by_hour.map((_, i) => String(i)), series: [{ name: "events", values: cl.per_week_by_hour }], height: 170, labelEvery: 3, format: v => v.toFixed(1) });
    barChart(s, { title: "By cause", categories: cl.by_cause.slice(0, 5).map(c => c.cause.replace(/_/g, " ")), series: [{ name: "share", values: cl.by_cause.slice(0, 5).map(c => c.share) }], height: 190, format: fmt.pct });
  }
  const es = D.event_study && D.event_study.overall;
  if (es) {
    const s = h("div", "section", null, body); h("span", "kicker", "How an incident unfolds", s);
    h("p", "lede", `Across ${D.event_study.n_alerts} unplanned alerts, trains showed the problem about ${Math.round(es.detection_lag_min)} min before the alert was posted, and service was back to normal ${Math.round(es.recovery_min)} min after.`, s);
    lineChart(s, { title: "Average excess delay around an alert", subtitle: "seconds, by minutes from the alert's posting", x: es.bins.map(String), series: [{ name: "excess delay", values: es.mean_curve }], height: 170, labelEvery: 6, format: v => `${Math.round(v)} s` });
  }
  if (D.holds && D.holds.by_hour) {
    const s = h("div", "section", null, body); h("span", "kicker", "Holds through the day", s);
    barChart(s, { title: "Holds per day starting in each hour", categories: D.holds.by_hour.map((_, i) => String(i)), series: [{ name: "holds", values: D.holds.by_hour }], height: 160, labelEvery: 3, format: v => v.toFixed(0) });
  }
  const s = h("div", "section", null, body); h("span", "kicker", "Live feeds in this browser", s);
  if (!E.feedInfo || !E.feedInfo.length) h("div", "empty-s", E.mode === "scheduled" ? "The MTA feeds could not be reached; trains are placed by the schedule." : "Waiting for the first poll…", s);
  for (const f of E.feedInfo || []) { const k = h("div", "kv", null, s); h("span", null, f.key, k); h("span", "mono", E.failedFeeds.has(f.key) ? "unreachable" : `${f.trips} trips · ${f.vehicles} trains · ${f.ms} ms`, k); }
  const src = h("p", "small-print", null, body);
  src.textContent = `Data: ${dataSource === "same-origin" ? "this site" : dataSource === "gh-pages" ? "the published gh-pages branch" : dataBase} · tables built ${ix.generated_at ? new Date(ix.generated_at).toLocaleString() : "–"} · ${(ix.sources || []).length} sources, see `;
  const a = h("a", null, "the data page", src); a.href = "../#/data";
}

// ---------------------------------------------------------------- timeline: replay today
function renderTimeline() {
  const el = $("#timeline"); if (!E || !E.trains) return;
  const now = E.now(), day0 = nyDayStart(now), span = 86400, xp = ts => `${Math.max(0, Math.min(100, (ts - day0) / span * 100))}%`;
  el.replaceChildren();
  const top = h("div", "tl-top", null, el);
  const ttl = h("span", null, null, top);
  if (S.replay == null) { h("b", null, "Today", ttl); h("span", "tl-desc", " · drag the timeline to replay train positions", ttl); }
  else { h("b", null, `Replaying ${hhmm(S.replay)}`, ttl); h("span", "tl-desc", E.history.length && S.replay >= E.history[0].ts ? " · recorded live positions" : " · scheduled positions (before this page opened)", ttl); }
  const sp = h("span", null, null, top); sp.style.flex = "1";
  h("span", null, "Bars: disruptions by hour (archive average) · red ticks: live incidents", top).className = "hide-sm";
  const back = h("button", "btn", "−15 min", top); back.type = "button"; back.addEventListener("click", () => setReplay((S.replay ?? now) - 900));
  const live = h("button", `btn${S.replay == null ? " primary" : ""}`, "Live", top); live.type = "button"; live.addEventListener("click", () => setReplay(null));
  const track = h("div", "tl-track", null, el);
  const bars = h("div", "tl-bars", null, track); const by = (D.climatology && D.climatology.per_week_by_hour) || Array(24).fill(1); const mx = Math.max(...by, 1e-9);
  by.forEach((v, i) => { const b = h("span", day0 + (i + 1) * 3600 <= now ? "past" : "", null, bars); b.style.height = `${Math.max(4, v / mx * 100)}%`; b.title = `${String(i).padStart(2, "0")}:00 · ${v.toFixed(1)} disruptions a week on average`; });
  if (E.history.length) { const r = h("div", "tl-range", null, track); r.style.left = xp(E.history[0].ts); r.style.width = `calc(${xp(now)} - ${xp(E.history[0].ts)})`; r.title = "Recorded live positions"; }
  for (const ev of E.events) { const m = h("div", "tl-ev", null, track); m.style.left = xp(ev.first_ts); m.title = ev.title; }
  const head = h("div", "tl-head", null, track); head.style.left = xp(S.replay ?? now);
  const axis = h("div", "tl-axis", null, track); for (const t of ["00:00", "06:00", "12:00", "18:00", "24:00"]) h("span", null, t, axis);
  const scrub = ev => { const r = track.getBoundingClientRect(); const ts = day0 + Math.max(0, Math.min(1, (ev.clientX - r.left) / r.width)) * span; setReplay(ts >= now - 20 ? null : ts); };
  track.addEventListener("pointerdown", ev => { track.setPointerCapture(ev.pointerId); scrub(ev); track.onpointermove = scrub; });
  track.addEventListener("pointerup", () => { track.onpointermove = null; });
}
function setReplay(ts) { const now = E.now(); S.replay = ts == null || ts >= now - 20 ? null : Math.max(nyDayStart(now), ts); drawTrains(); renderTimeline(); renderModePill(); }

// ---------------------------------------------------------------- boot
const { base, source } = await resolveDataBase();
load = makeLoader(base); dataBase = base; dataSource = source;
readHash();
initChrome();
initMap();
for (const f of ["index", "live", "scorecard", "digest", "alerts", "holds", "dwell", "climatology", "lines", "event_study", "train_runs", "eta_trust", "routes", "status"])
  load(`${f}.json`).then(v => { D[f] = v; if (E && E.mode !== "loading") renderAll(); });
E = createEngine({ base, load, onUpdate: () => { onEngine(); }, onStatus: st => { if (st.error) toast(`Live feeds unreachable, showing scheduled positions (${st.error})`); } });
E.start().catch(err => { $("#mode .txt").textContent = "Could not load the network data"; toast(String(err.message || err), 10000); console.error(err); });

