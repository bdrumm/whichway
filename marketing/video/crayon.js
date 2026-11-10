// A child's drawing, for a film told in crayon: wax marks that skip on the paper's tooth, scribbled fills, lines that
// wander and "boil" like hand-drawn animation, and a ball-and-stick alphabet that writes itself. Loads after kit.js and nyc.js.
// A film calls page(t, cam, draw); inside draw, every mark is given the time the hand starts it and how long it takes.
const CRAYON = {
  black: '#2a2522', red: '#d7352c', orange: '#f0791b', yellow: '#f0b40c', green: '#3d9a48', blue: '#2c69c9', sky: '#55a9e2',
  purple: '#7647bd', pink: '#e2337f', brown: '#85552f', gray: '#858a94', skin: '#e3a06c',
};
const PAPER_M = 260;   // paper beyond the frame, so the camera can move over the sheet
const PAPERC = (() => {
  const c = document.createElement('canvas'); c.width = W + PAPER_M * 2; c.height = H + PAPER_M * 2;
  const g = c.getContext('2d'), r = rng(404);
  g.fillStyle = '#f5efe2'; g.fillRect(0, 0, c.width, c.height);
  for (let i = 0; i < 11000; i++) {   // fibres
    const x = r() * c.width, y = r() * c.height, a = r() * Math.PI, l = 4 + r() * 18;
    g.strokeStyle = r() < 0.5 ? 'rgba(120,96,60,0.06)' : 'rgba(255,255,255,0.4)'; g.lineWidth = 0.8; g.beginPath(); g.moveTo(x, y); g.lineTo(x + Math.cos(a) * l, y + Math.sin(a) * l); g.stroke();
  }
  for (let i = 0; i < 3200; i++) { g.fillStyle = `rgba(110,84,50,${0.03 + r() * 0.07})`; g.fillRect(r() * c.width, r() * c.height, 1 + r() * 1.6, 1 + r() * 1.6); }
  const v = g.createRadialGradient(c.width / 2, c.height / 2, 520, c.width / 2, c.height / 2, 1450); v.addColorStop(0, 'rgba(150,112,64,0)'); v.addColorStop(1, 'rgba(150,112,64,0.2)');
  g.fillStyle = v; g.fillRect(0, 0, c.width, c.height);
  return c;
})();
// the tooth of the paper: where the wax does not take
const TOOTH = (() => {
  const n = 512, c = document.createElement('canvas'); c.width = c.height = n;
  const g = c.getContext('2d'), im = g.createImageData(n, n), r = rng(77), q = n / 4, blot = Array.from({ length: q * q }, () => r());
  for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) im.data[(y * n + x) * 4 + 3] = 255 * clamp((0.6 * r() + 0.4 * blot[(y >> 2) * q + (x >> 2)] - 0.58) * 4.5);
  g.putImageData(im, 0, 0);
  const big = document.createElement('canvas'); big.width = big.height = n * 2; big.getContext('2d').drawImage(c, 0, 0, n * 2, n * 2);
  return big;
})();
const WAXC = document.createElement('canvas'); WAXC.width = W; WAXC.height = H;
const wx = WAXC.getContext('2d'), TOOTHP = wx.createPattern(TOOTH, 'repeat');
let NOW = 0, BOIL = 0;   // the page's clock, and which of the six drawings a second we are on

/** One sheet. `cam`: k (zoom), fx, fy (the point of the sheet at the centre of the frame), rot, dx (slide the whole
 *  sheet sideways, px, for a page coming in). `draw` makes the marks. */
function page(t, cam, draw) {
  const { k = 1, fx = W / 2, fy = H / 2, rot = 0, dx = 0 } = cam;
  const apply = g => { g.translate(W / 2 + dx, H / 2); g.rotate(rot); g.scale(k, k); g.translate(-fx, -fy); };
  NOW = t; BOIL = Math.floor(t * 6);
  ctx.save(); apply(ctx);
  if (dx) { const s = ctx.createLinearGradient(-PAPER_M - 90, 0, -PAPER_M, 0); s.addColorStop(0, 'rgba(0,0,0,0)'); s.addColorStop(1, 'rgba(0,0,0,0.3)'); ctx.fillStyle = s; ctx.fillRect(-PAPER_M - 90, -PAPER_M, 90, H + PAPER_M * 2); }
  ctx.drawImage(PAPERC, -PAPER_M, -PAPER_M); ctx.restore();
  wx.setTransform(1, 0, 0, 1, 0, 0); wx.globalCompositeOperation = 'source-over'; wx.globalAlpha = 1; wx.clearRect(0, 0, W, H);
  wx.save(); apply(wx); wx.lineCap = 'round'; wx.lineJoin = 'round';
  draw();
  wx.globalCompositeOperation = 'destination-out'; wx.globalAlpha = 1; wx.fillStyle = TOOTHP; wx.fillRect(-PAPER_M, -PAPER_M, W + PAPER_M * 2, H + PAPER_M * 2);
  wx.restore();
  ctx.save(); ctx.globalCompositeOperation = 'multiply'; ctx.drawImage(WAXC, 0, 0); ctx.restore();
}
/** The hand: a line resampled every `step` px, wandering off true (fixed to the line) and boiling a little. */
function hand(pts, seed, wob, boil, step) {
  const out = []; let s = 0;
  for (let i = 0; i < pts.length - 1; i++) {
    const [x0, y0] = pts[i], [x1, y1] = pts[i + 1], d = Math.hypot(x1 - x0, y1 - y0), n = Math.max(1, Math.round(d / step));
    for (let j = i ? 1 : 0; j <= n; j++) {
      const k = j / n, q = s + d * k;
      out.push([lerp(x0, x1, k) + noise1(q * 0.019, seed) * wob + noise1(q * 0.11 + BOIL * 3.7, seed + 9) * boil,
        lerp(y0, y1, k) + noise1(q * 0.019, seed + 4) * wob + noise1(q * 0.11 + BOIL * 3.7, seed + 13) * boil]);
    }
    s += d;
  }
  return out;
}
/** One crayon mark along `pts`, `w` wide, begun at `at` and taking `dur` seconds to draw. */
function mark(pts, color, w, at, dur = 0.4, { seed = 1, wob = 2.4, boil = 1.0, step = 10, press = 1 } = {}) {
  const k = dur > 0 ? seg(NOW, at, at + dur) : (NOW >= at ? 1 : 0); if (k <= 0) return;
  const p = hand(pts, (pts[0][0] * 0.37 + pts[0][1] * 0.11 + seed * 7.3) % 997, wob, boil, step), n = (p.length - 1) * k, m = Math.floor(n), f = n - m;
  const path = (dx, dy) => {
    wx.beginPath(); wx.moveTo(p[0][0] + dx, p[0][1] + dy);
    for (let i = 1; i <= m; i++) wx.lineTo(p[i][0] + dx, p[i][1] + dy);
    if (m < p.length - 1 && f > 0) wx.lineTo(lerp(p[m][0], p[m + 1][0], f) + dx, lerp(p[m][1], p[m + 1][1], f) + dy);
  };
  wx.strokeStyle = color;
  wx.globalAlpha = 0.74 * press; wx.lineWidth = w; path(0, 0); wx.stroke();
  wx.globalAlpha = 0.5 * press; wx.lineWidth = w * 0.5; path(w * 0.12, -w * 0.1); wx.stroke();   // the waxier middle of the stroke
}
/** The zigzag a child fills a shape with: back and forth across `poly` at `angle`, lines `gap` apart, overshooting. */
function hatch(poly, angle, gap, seed, over) {
  const c = Math.cos(angle), s = Math.sin(angle), R = poly.map(([x, y]) => [x * c + y * s, -x * s + y * c]), r = rng(Math.round(seed * 97) + 5);
  const ys = R.map(p => p[1]), out = []; let flip = false;
  for (let y = Math.min(...ys) + gap * 0.5; y < Math.max(...ys); y += gap * (0.8 + 0.4 * r())) {
    const xs = [];
    R.forEach(([xa, ya], i) => { const [xb, yb] = R[(i + 1) % R.length]; if ((ya <= y) !== (yb <= y)) xs.push(xa + (y - ya) * (xb - xa) / (yb - ya)); });
    if (xs.length < 2) continue;
    const a = Math.min(...xs) + (0.35 - r()) * over, b = Math.max(...xs) - (0.35 - r()) * over;
    out.push(flip ? [b, y] : [a, y], flip ? [a, y + gap * 0.3] : [b, y + gap * 0.3]); flip = !flip;
  }
  return out.map(([x, y]) => [x * c - y * s, x * s + y * c]);
}
function scribble(poly, color, at, dur, { angle = -0.55, gap = 14, w = 13, seed = 1, over = 9, press = 0.7 } = {}) {
  const pts = hatch(poly, angle, gap, seed, over); if (pts.length > 1) mark(pts, color, w, at, dur, { seed, wob: 1.6, boil: 0.9, step: 26, press });
}
const rectPts = (x, y, w, h) => [[x, y], [x + w, y], [x + w, y + h], [x, y + h], [x, y - 7]];   // a box closed past its corner
const boxPoly = (x, y, w, h) => [[x, y], [x + w, y], [x + w, y + h], [x, y + h]];
/** An oval drawn in one go, starting at `a0` degrees and running a little past where it began. */
const ovalPts = (cx, cy, rx, ry = rx, a0 = -100, turn = 388) => Array.from({ length: 27 }, (_, i) => { const a = (a0 + turn * i / 26) * Math.PI / 180; return [cx + rx * Math.cos(a), cy + ry * Math.sin(a)]; });
const ovalPoly = (cx, cy, rx, ry = rx) => ovalPts(cx, cy, rx, ry, 0, 346);
/** Motion drawn "on twos": time that only moves `fps` times a second. */
const onTwos = (t, fps = 8) => Math.floor(t * fps) / fps;

// ---------- the alphabet: balls and sticks, as it is taught. Baseline 0, a small letter 1 tall, a tall one 2, y up ----------
const _A = (cx, cy, rx, a0, a1, ry = rx) => { const n = Math.max(4, Math.round(Math.abs(a1 - a0) / 20)); return Array.from({ length: n + 1 }, (_, i) => { const a = (a0 + (a1 - a0) * i / n) * Math.PI / 180; return [cx + rx * Math.cos(a), cy + ry * Math.sin(a)]; }); };
const _O = (cx, cy, rx, ry = rx) => _A(cx, cy, rx, 60, 445, ry);
const _D = (x, y) => _A(x, y, 0.05, 0, 360);
const GLYPH = {
  a: { w: 1.1, s: [_O(0.5, 0.5, 0.5), [[1, 1.05], [1, 0]]] },
  b: { w: 1.1, s: [[[0, 2], [0, 0]], _O(0.52, 0.5, 0.5)] },
  c: { w: 0.95, s: [_A(0.5, 0.5, 0.5, 50, 310)] },
  d: { w: 1.1, s: [_O(0.5, 0.5, 0.5), [[1, 2], [1, 0]]] },
  e: { w: 1.05, s: [[[0.03, 0.52], [0.97, 0.52], ..._A(0.5, 0.5, 0.5, 0, 305).slice(1)]] },
  f: { w: 0.8, s: [[..._A(0.62, 1.6, 0.38, 10, 180), [0.24, 0]], [[-0.05, 1], [0.6, 1]]] },
  g: { w: 1.1, s: [_O(0.5, 0.5, 0.5), [[1, 1.05], [1, -0.5], ..._A(0.5, -0.5, 0.5, 0, -160).slice(1)]] },
  h: { w: 1.0, s: [[[0, 2], [0, 0]], [[0, 0.5], ..._A(0.45, 0.55, 0.45, 180, 0), [0.9, 0]]] },
  i: { w: 0.3, s: [[[0, 1], [0, 0]], _D(0, 1.5)] },
  j: { w: 0.6, s: [[[0.4, 1], [0.4, -0.5], ..._A(0.05, -0.5, 0.35, 0, -150).slice(1)], _D(0.4, 1.5)] },
  k: { w: 0.95, s: [[[0, 2], [0, 0]], [[0.8, 1], [0.05, 0.45], [0.85, 0]]] },
  l: { w: 0.3, s: [[[0, 2], [0, 0]]] },
  m: { w: 1.72, s: [[[0, 1], [0, 0]], [[0, 0.55], ..._A(0.42, 0.58, 0.42, 180, 0), [0.84, 0]], [[0.84, 0.55], ..._A(1.26, 0.58, 0.42, 180, 0), [1.68, 0]]] },
  n: { w: 1.0, s: [[[0, 1], [0, 0]], [[0, 0.5], ..._A(0.45, 0.55, 0.45, 180, 0), [0.9, 0]]] },
  o: { w: 1.05, s: [_O(0.5, 0.5, 0.5)] },
  p: { w: 1.1, s: [[[0, 1], [0, -1]], _O(0.52, 0.5, 0.5)] },
  q: { w: 1.1, s: [_O(0.5, 0.5, 0.5), [[1, 1], [1, -1]]] },
  r: { w: 0.8, s: [[[0, 1], [0, 0]], [[0, 0.5], ..._A(0.42, 0.55, 0.42, 180, 35)]] },
  s: { w: 0.8, s: [[..._A(0.4, 0.74, 0.27, 40, 270), ..._A(0.4, 0.26, 0.27, 90, -140).slice(1)]] },
  t: { w: 0.75, s: [[[0.33, 1.75], [0.33, 0]], [[0, 1], [0.7, 1]]] },
  u: { w: 1.0, s: [[[0, 1], [0, 0.45], ..._A(0.45, 0.45, 0.45, 180, 360), [0.9, 1]], [[0.9, 1], [0.9, 0]]] },
  v: { w: 0.95, s: [[[0, 1], [0.45, 0], [0.9, 1]]] },
  w: { w: 1.45, s: [[[0, 1], [0.33, 0], [0.68, 0.85], [1.03, 0], [1.36, 1]]] },
  x: { w: 0.9, s: [[[0, 1], [0.85, 0]], [[0.85, 1], [0, 0]]] },
  y: { w: 0.95, s: [[[0, 1], [0.45, 0.05]], [[0.9, 1], [0.15, -0.95]]] },
  z: { w: 0.9, s: [[[0, 1], [0.8, 1], [0, 0], [0.8, 0]]] },
  A: { w: 1.3, s: [[[0, 0], [0.6, 2], [1.2, 0]], [[0.25, 0.8], [0.95, 0.8]]] },
  C: { w: 1.3, s: [_A(0.75, 1, 0.75, 50, 310, 1)] },
  E: { w: 1.1, s: [[[0, 2], [0, 0]], [[0, 2], [1, 2]], [[0, 1.05], [0.8, 1.05]], [[0, 0], [1, 0]]] },
  F: { w: 1.05, s: [[[0, 2], [0, 0]], [[0, 2], [1, 2]], [[0, 1.05], [0.75, 1.05]]] },
  H: { w: 1.15, s: [[[0, 2], [0, 0]], [[1, 2], [1, 0]], [[0, 1], [1, 1]]] },
  I: { w: 0.9, s: [[[0.4, 2], [0.4, 0]], [[0, 2], [0.8, 2]], [[0, 0], [0.8, 0]]] },
  L: { w: 1.0, s: [[[0, 2], [0, 0], [0.9, 0]]] },
  M: { w: 1.55, s: [[[0, 0], [0, 2], [0.7, 0.8], [1.4, 2], [1.4, 0]]] },
  N: { w: 1.15, s: [[[0, 0], [0, 2], [1, 0], [1, 2]]] },
  O: { w: 1.45, s: [_O(0.7, 1, 0.7, 1)] },
  S: { w: 1.15, s: [[..._A(0.55, 1.5, 0.5, 40, 270), ..._A(0.55, 0.5, 0.5, 90, -140).slice(1)]] },
  T: { w: 1.25, s: [[[0, 2], [1.2, 2]], [[0.6, 2], [0.6, 0]]] },
  0: { w: 1.1, s: [_O(0.5, 1, 0.5, 1)] },
  1: { w: 0.7, s: [[[0.1, 1.5], [0.45, 2], [0.45, 0]]] },
  2: { w: 1.1, s: [[..._A(0.5, 1.5, 0.5, 160, -50), [0, 0], [1, 0]]] },
  3: { w: 1.05, s: [[..._A(0.45, 1.5, 0.5, 150, -90), ..._A(0.45, 0.5, 0.5, 90, -150).slice(1)]] },
  6: { w: 1.1, s: [[..._A(0.75, 0.95, 0.7, 75, 180, 1.05), ..._A(0.55, 0.5, 0.5, 180, 545).slice(1)]] },
  ':': { w: 0.35, s: [_D(0.12, 1.1), _D(0.12, 0.2)] },
  '.': { w: 0.3, s: [_D(0.08, 0.06)] },
  ',': { w: 0.35, s: [[[0.15, 0.12], [0.02, -0.32]]] },
  '!': { w: 0.35, s: [[[0.1, 2], [0.1, 0.55]], _D(0.1, 0.06)] },
};
const _len = st => st.reduce((a, p, i) => (i ? a + Math.hypot(p[0] - st[i - 1][0], p[1] - st[i - 1][1]) : 0), 0);
/** Where each letter of `s` goes: no two the same size, none quite on the line. `size` is the height of a small letter. */
function letters(s, size, seed = 1) {
  let x = 0; const out = [];
  [...s].forEach((ch, i) => {
    if (ch === ' ') { x += size * 0.72; return; }
    const g = GLYPH[ch]; if (!g) throw new Error('crayon.js has no letter ' + ch);
    const sc = size * (0.93 + 0.14 * hash(seed * 31 + i * 7.7));
    out.push({ g, i, x, sc, dy: (hash(seed * 17 + i * 3.1) - 0.5) * size * 0.16, rot: (hash(seed * 5 + i * 11.3) - 0.5) * 0.13 });
    x += g.w * sc + size * 0.3;
  });
  return { out, width: x - size * 0.3 };
}
const writeWidth = (s, size, seed = 1) => letters(s, size, seed).width;
/** How long the hand takes over `s` at `per` seconds a letter (a space is a short breath). */
const writeTime = (s, per = 0.1) => [...s].reduce((a, ch) => a + (ch === ' ' ? per * 0.5 : per), 0);
/** Write `s` from (x, y) on its baseline, starting at `at`. `rise` tilts the line (a child's lines climb). Returns
 *  the x where the next word would start. */
function write(s, x, y, size, color, at, { per = 0.1, w = size * 0.2, seed = 1, rise = 0 } = {}) {
  const lay = letters(s, size, seed), chars = [...s]; let k = 0, tAt = at;
  lay.out.forEach(({ g, i, x: gx, sc, dy, rot }) => {
    while (k < i) { tAt += chars[k] === ' ' ? per * 0.5 : per; k++; }
    const c = Math.cos(rot), sn = Math.sin(rot), total = g.s.reduce((a, st) => a + _len(st) + 0.3, 0); let st0 = tAt;
    g.s.forEach((st, j) => {
      const d = per * 0.92 * (_len(st) + 0.3) / total;
      mark(st.map(([px, py]) => [x + gx + (px * c + py * sn) * sc, y + dy - rise * gx + (px * sn - py * c) * sc]), color, w, st0, d, { seed: seed + i * 13 + j * 5, wob: size * 0.04, boil: size * 0.02, step: 6 });
      st0 += d;
    });
  });
  return x + lay.width + size * 1.02;
}
