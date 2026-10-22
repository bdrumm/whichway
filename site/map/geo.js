// Line geometry for the map: each exported line (route_direction) has one coordinate per stop and a
// track shape. Stops are projected onto the shape once, so a train at a fractional stop index
// (see trainProgress in rt-client.js) is placed on the track rather than on the chord between stations.

const R = 6371000, RAD = Math.PI / 180;
// equirectangular metres around NYC: plenty for a few km of track
const xy = ([lat, lon]) => [lon * RAD * R * Math.cos(40.7 * RAD), lat * RAD * R];
const dist = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1]);

function projectOnto(pts, cum, p, fromSeg) {
  let best = { d: Infinity, at: cum[fromSeg] || 0, seg: fromSeg };
  for (let i = fromSeg; i < pts.length - 1; i++) {
    const a = pts[i], b = pts[i + 1], dx = b[0] - a[0], dy = b[1] - a[1], L2 = dx * dx + dy * dy;
    const t = L2 ? Math.max(0, Math.min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / L2)) : 0;
    const q = [a[0] + t * dx, a[1] + t * dy], d = dist(p, q);
    if (d < best.d) best = { d, at: cum[i] + t * (cum[i + 1] - cum[i]), seg: i };
  }
  return best;
}

/** One line's geometry: lngLat at a fractional stop index, the track between two stop indices, bearing. */
export function buildLine(geo) {
  const stops = geo.coords;
  let shape = geo.shape && geo.shape.length > 1 ? geo.shape : stops;
  // shapes are exported in one direction; align with this line's stop order
  if (dist(xy(shape[0]), xy(stops[0])) > dist(xy(shape[shape.length - 1]), xy(stops[0]))) shape = [...shape].reverse();
  const pts = shape.map(xy), cum = [0];
  for (let i = 1; i < pts.length; i++) cum.push(cum[i - 1] + dist(pts[i - 1], pts[i]));
  // project each stop forward along the shape; fall back to straight chords when the shape is off (> 400 m)
  let seg = 0, ok = true; const at = [];
  for (const s of stops) {
    const p = projectOnto(pts, cum, xy(s), seg);
    if (p.d > 400 || (at.length && p.at < at[at.length - 1])) { ok = false; break; }
    at.push(p.at); seg = p.seg;
  }
  const lngLat = ll => [ll[1], ll[0]];
  function alongShape(d) {
    let lo = 0, hi = cum.length - 1;
    while (hi - lo > 1) { const m = (lo + hi) >> 1; if (cum[m] <= d) lo = m; else hi = m; }
    const span = cum[hi] - cum[lo], t = span ? (d - cum[lo]) / span : 0;
    const a = shape[lo], b = shape[hi];
    return [a[1] + t * (b[1] - a[1]), a[0] + t * (b[0] - a[0])];
  }
  const n = stops.length;
  return {
    n,
    stop: i => lngLat(stops[Math.max(0, Math.min(n - 1, i))]),
    /** lngLat at fractional stop index f */
    at(f) {
      f = Math.max(0, Math.min(n - 1, f));
      const j = Math.min(n - 2, Math.floor(f)), t = f - j;
      if (n < 2) return lngLat(stops[0]);
      if (ok) return alongShape(at[j] + t * (at[j + 1] - at[j]));
      const a = stops[j], b = stops[j + 1];
      return [a[1] + t * (b[1] - a[1]), a[0] + t * (b[0] - a[0])];
    },
    /** coordinates of the track from stop index i to stop index k (i < k) */
    between(i, k) {
      i = Math.max(0, i); k = Math.min(n - 1, k);
      if (!ok) return stops.slice(i, k + 1).map(lngLat);
      const d0 = at[i], d1 = at[k], out = [alongShape(d0)];
      for (let q = 0; q < cum.length; q++) if (cum[q] > d0 && cum[q] < d1) out.push(lngLat(shape[q]));
      out.push(alongShape(d1));
      return out;
    },
    full: () => (ok ? shape : stops).map(lngLat),
  };
}

export const bboxOf = coords => {
  let w = 180, s = 90, e = -180, n = -90;
  for (const [x, y] of coords) { if (x < w) w = x; if (x > e) e = x; if (y < s) s = y; if (y > n) n = y; }
  return [[w, s], [e, n]];
};
