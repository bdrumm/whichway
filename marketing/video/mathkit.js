// The math the films open on: arrivals falling through a Galton board until "when?" is a curve, and the city as a
// living graph with a curve riding on every train. Needs kit.js, pickup-kit.js (WARM) and engine.js (NETWORK, gauss).
const BRIGHT = ['#ff6319', '#fccc0a', '#ee352e', '#3ddc97', '#b933ad', '#6cbe45', '#5b9bff', '#c9ccd1'];

// ---------- 1: the Galton board ----------
const G = { cx: 1340, top: 190, dx: 52, dy: 38, rows: 11, base: 950, unit: 4.1, step: 0.13, n: 320 };
const BALLS = (() => {
  const r = rng(41), out = [];
  for (let i = 0; i < G.n; i++) {
    const ks = [0]; for (let s = 0; s < G.rows; s++) ks.push(ks[s] + (r() < 0.5 ? 0 : 1));
    out.push({ f: Math.pow(i / G.n, 0.55), ks, color: BRIGHT[i % BRIGHT.length], bin: ks[G.rows] });
  }
  return out;
})();
const G_DROP = 0.32;
const gx = (k, row) => G.cx + (k - row / 2) * G.dx;
const G_SD = Math.sqrt(G.rows) / 2 * G.dx, G_PEAK = 0.2256 * G.n * G.unit * 1.04;
/** The board. `o` times it: the first dot at `first`, the last `spread` later, a peg row every `step`; the curve
 *  draws over `curve` and the 8-in-10 window opens at `win`; `cx` places it; `trails` and `r` dress the dots. */
function galton(t, a, o = {}) {
  if (a <= 0) return;
  const { first = 0.9, spread = 8.3, step = G.step, curve = [9.4, 11.2], win: winAt = 10.9, cx = G.cx, trails = 0, r = 6.5, label = 'EVERY ARRIVAL, ONE DOT' } = o;
  const fall = G.rows * step;
  ctx.save(); ctx.translate(cx - G.cx, 0);
  ctx.save(); ctx.globalAlpha *= a;
  text(label, G.cx - 312, 120, { size: 18, weight: 700, color: ENG.label, spacing: 3, display: false });
  // pegs
  for (let row = 0; row < G.rows; row++) for (let i = 0; i <= row; i++) {
    ctx.fillStyle = 'rgba(156,196,255,0.5)'; ctx.beginPath(); ctx.arc(gx(i, row), G.top + row * G.dy, 3.6, 0, Math.PI * 2); ctx.fill();
  }
  // what has landed, and what is falling
  const counts = new Array(G.rows + 1).fill(0);
  const fade = 1 - 0.75 * easeInOut(seg(t, curve[0] + 0.2, curve[1]));   // the columns give way to the curve
  const at = (b, tt) => {   // where dot b is at time tt, or null once it has landed
    const t0 = first + spread * b.f, u = (tt - t0) / step;
    if (u < 0) return undefined;
    if (tt >= t0 + fall + G_DROP) return null;
    if (u < G.rows) {
      const row = Math.floor(u), f = u - row;
      return [lerp(gx(b.ks[row], row), gx(b.ks[row + 1], row + 1), easeInOut(f)), G.top + (u - 1) * G.dy - Math.sin(f * Math.PI) * 9];
    }
    const f = (tt - t0 - fall) / G_DROP;
    return [gx(b.bin, G.rows), lerp(G.top + (G.rows - 1) * G.dy, G.base - 8, f * f)];
  };
  BALLS.forEach(b => {
    const p = at(b, t);
    if (p === undefined) return;
    if (p === null) { counts[b.bin]++; return; }
    ctx.fillStyle = b.color; ctx.shadowColor = b.color; ctx.shadowBlur = 14 + trails * 2;
    for (let k = trails; k > 0; k--) {
      const q = at(b, t - k * 0.022);
      if (q) { ctx.globalAlpha = a * 0.5 * (1 - k / (trails + 1)); ctx.beginPath(); ctx.arc(q[0], q[1], r * (1 - 0.1 * k), 0, Math.PI * 2); ctx.fill(); }
    }
    ctx.globalAlpha = a;
    ctx.beginPath(); ctx.arc(p[0], p[1], r, 0, Math.PI * 2); ctx.fill();
  });
  ctx.shadowBlur = 0;
  counts.forEach((c, k) => {
    if (!c) return;
    const h = c * G.unit, x = gx(k, G.rows) - G.dx / 2 + 5;
    const g = ctx.createLinearGradient(0, G.base - h, 0, G.base); g.addColorStop(0, `rgba(156,196,255,${0.85 * fade})`); g.addColorStop(1, `rgba(46,124,255,${0.25 * fade})`);
    ctx.beginPath(); ctx.roundRect(x, G.base - h, G.dx - 10, h, [6, 6, 0, 0]); ctx.fillStyle = g; ctx.fill();
  });
  ctx.fillStyle = ENG.axis; ctx.fillRect(G.cx - 330, G.base, 660, 2);
  text('sooner', G.cx - 330, G.base + 34, { size: 17, weight: 600, color: ENG.label, spacing: 2, display: false });
  text('later', G.cx + 330, G.base + 34, { size: 17, weight: 600, color: ENG.label, spacing: 2, align: 'right', display: false });
  // the shape they make
  const d = easeInOut(seg(t, curve[0], curve[1]));
  if (d > 0) {
    const x0 = G.cx - 330, x1 = lerp(x0, G.cx + 330, d), Y = x => G.base - gauss(x, G.cx, G_SD) * G_PEAK;
    const win = easeOut(seg(t, winAt, winAt + 0.8));
    if (win > 0) {   // where eight in ten land
      const lo = G.cx - 1.28 * G_SD, hi = G.cx + 1.28 * G_SD, w = new Path2D(); w.moveTo(lo, G.base);
      for (let x = lo; x <= hi; x += 3) w.lineTo(x, Y(x)); w.lineTo(hi, G.base); w.closePath();
      const g = ctx.createLinearGradient(0, G.base - G_PEAK, 0, G.base); g.addColorStop(0, `rgba(255,216,154,${0.42 * win})`); g.addColorStop(1, `rgba(255,216,154,${0.04 * win})`);
      ctx.fillStyle = g; ctx.fill(w);
      text('8 in 10 land here', G.cx, G.base + 34, { size: 19, weight: 700, color: WARM, align: 'center', alpha: win, display: false });
    }
    const p = new Path2D(); p.moveTo(x0, Y(x0));
    for (let x = x0; x <= x1; x += 3) p.lineTo(x, Y(x));
    glowStroke(p, WARM, 5, 22, 1);
  }
  ctx.restore();
  ctx.restore();
}

// ---------- 2: the city, every train with its own curve ----------
const MINE = { line: 8, k: 2 };   // the one train the film follows out of the crowd (the 6)
/** The network as a living graph. `o.draw` is when the lines draw themselves, `o.pick` when one train is picked out
 *  of the crowd; `o.scrim` darkens the left for the words. */
function city(t, a, o = {}) {
  if (a <= 0) return;
  const { draw: dr = [12.6, 15.6], pick: pk = [18.6, 20.6], scrim = true } = o;
  const draw = easeInOut(seg(t, dr[0], dr[1])), pick = easeInOut(seg(t, pk[0], pk[1]));
  ctx.save(); ctx.globalAlpha *= a;
  ctx.save(); ctx.translate(W, H / 2); ctx.scale(0.76, 0.76); ctx.translate(-W + 50, -H / 2);   // set to the right of the words
  NETWORK.forEach((l, i) => {
    ctx.save(); ctx.setLineDash([l.len * draw, l.len * 2]);
    glowStroke(l.path, L[l.n], 5, 12, 0.6 * (1 - 0.5 * pick)); ctx.restore();
    // stations: the nodes of the graph, each one breathing
    l.P.forEach(([x, y], s) => {
      if (draw < l.lens[s] / l.len) return;
      const beat = 0.5 + 0.5 * Math.sin(t * 2.2 + i * 1.3 + s);
      ctx.strokeStyle = `rgba(244,246,251,${(0.25 + 0.3 * beat) * (1 - 0.5 * pick)})`; ctx.lineWidth = 2;
      ctx.beginPath(); ctx.arc(x, y, 7 + beat * 5, 0, Math.PI * 2); ctx.stroke();
      ctx.fillStyle = `rgba(244,246,251,${0.9 * (1 - 0.5 * pick)})`; ctx.beginPath(); ctx.arc(x, y, 3.5, 0, Math.PI * 2); ctx.fill();
    });
    const r = rng(i + 50), n = Math.round(l.len / 170);
    for (let k = 0; k < n; k++) {
      const f = ((r() + (k % 2 ? 1 : -1) * t * (0.02 + r() * 0.01)) % 1 + 1) % 1, [x, y] = netAt(l, f);
      if (f > draw) continue;
      const mine = i === MINE.line && k === MINE.k, lit = mine ? 1 : 1 - 0.7 * pick;
      // the train, and above it the shape of when it gets where it is going
      const sd = (9 + 7 * (0.5 + 0.5 * noise1(t * 0.5 + k * 3.1, i))) * (mine ? lerp(1, 2.4, pick) : 1), hgt = (mine ? lerp(26, 70, pick) : 26);
      const p = new Path2D();
      for (let q = -3; q <= 3.01; q += 0.25) { const px = x + q * sd, py = y - 14 - gauss(q, 0, 1) * hgt; q === -3 ? p.moveTo(px, py) : p.lineTo(px, py); }
      ctx.save(); ctx.globalAlpha *= lit;
      glowStroke(p, mine ? WARM : C.ice, mine ? lerp(2, 4, pick) : 2, mine ? 16 : 6, mine ? 1 : 0.7);
      ctx.fillStyle = '#fff'; ctx.shadowColor = '#fff'; ctx.shadowBlur = 12;
      ctx.beginPath(); ctx.arc(x, y, mine ? lerp(4.5, 8, pick) : 4.5, 0, Math.PI * 2); ctx.fill();
      ctx.restore();
    }
  });
  ctx.restore();
  // room for the words
  if (!scrim) { ctx.restore(); return; }
  const g = ctx.createLinearGradient(0, 0, 1000, 0); g.addColorStop(0, 'rgba(5,7,13,0.96)'); g.addColorStop(0.6, 'rgba(5,7,13,0.8)'); g.addColorStop(1, 'rgba(5,7,13,0)');
  ctx.fillStyle = g; ctx.fillRect(0, 0, 1000, H);
  ctx.restore();
}
