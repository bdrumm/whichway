// New York, drawn: the illustration kit for the illustrated cut of "Under the Clock". Night-poster colour, flat shapes,
// light as the subject. The skyline and the bridge, the concourse with its clock and its ceiling of stars, subway cars
// (the red ones of 1986 and today's steel), the tunnel, a wet street of brownstones with the green globes of a subway
// entrance, an island platform, and people: figures with a walk, a run, a wait and an embrace. Needs kit.js.

const NY = {
  ink: '#05060f', night0: '#060a1e', night1: '#1d2150', haze: '#3b2a5a', win: [255, 205, 120], taxi: '#ffc62e', globe: '#3ee08f',
  red: '#e0352b', gold: '#f2c14e', brass: '#c9973a', teal: '#1d6e73', steel: '#aeb8c6', redbird: '#8a221c',
};
const hex3 = c => [1, 3, 5].map(i => parseInt(c.slice(i, i + 2), 16));
/** Two #rrggbb colours mixed, k of the way from a to b. */
const mix = (a, b, k) => { const A = hex3(a), Bc = hex3(b); return `rgb(${A.map((v, i) => Math.round(lerp(v, Bc[i], k))).join(',')})`; };
const hash = n => { const s = Math.sin(n * 127.1 + 311.7) * 43758.5453; return s - Math.floor(s); };
function poly(pts, fill) { ctx.beginPath(); pts.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y))); ctx.closePath(); ctx.fillStyle = fill; ctx.fill(); }
/** Light, added to what is under it. */
function glowAt(x, y, r, rgb, a) {
  if (a <= 0 || r <= 0) return;
  ctx.save(); ctx.globalCompositeOperation = 'lighter';
  const g = ctx.createRadialGradient(x, y, 0, x, y, r); g.addColorStop(0, `rgba(${rgb},${a})`); g.addColorStop(1, `rgba(${rgb},0)`);
  ctx.fillStyle = g; ctx.fillRect(x - r, y - r, r * 2, r * 2); ctx.restore();
}
/** Run `fn` through a camera: scale k about the point (fx, fy), which lands at the centre of the frame (or at `at`). */
function camera(k, fx, fy, fn, at = [W / 2, H / 2]) { ctx.save(); ctx.translate(at[0], at[1]); ctx.scale(k, k); ctx.translate(-fx, -fy); fn(); ctx.restore(); }
function rain(t, a = 1, n = 260, slant = 0.2) {
  if (a <= 0) return;
  const r = rng(77);
  ctx.save(); ctx.strokeStyle = '#b9d2ff'; ctx.lineCap = 'round';
  for (let i = 0; i < n; i++) {
    const z = r(), sp = 900 + z * 1100, len = 22 + z * 46;
    const y = ((r() * (H + 200) + t * sp) % (H + 200)) - 100, x = ((r() * (W + 400) - t * sp * slant) % (W + 400) + W + 400) % (W + 400) - 200;
    ctx.globalAlpha = a * (0.08 + z * 0.22); ctx.lineWidth = 1 + z * 1.4;
    ctx.beginPath(); ctx.moveTo(x, y); ctx.lineTo(x - len * slant, y + len); ctx.stroke();
  }
  ctx.restore();
}
function steam(x, y, t, s = 1, a = 1, rgb = '220,225,240') {
  for (let i = 0; i < 9; i++) {
    const k = ((t * 0.22 + i / 9) % 1), px = x + noise1(t * 0.5 + i * 3, i) * 50 * k * s + k * 60 * s, py = y - k * 260 * s, r = (30 + k * 110) * s;
    const g = ctx.createRadialGradient(px, py, 0, px, py, r); g.addColorStop(0, `rgba(${rgb},${0.22 * a * (1 - k)})`); g.addColorStop(1, `rgba(${rgb},0)`);
    ctx.fillStyle = g; ctx.fillRect(px - r, py - r, r * 2, r * 2);
  }
}

// ---------- the skyline ----------
function makeBlock(seed, x0, x1, hMin, hMax, wMin, wMax) {
  const r = rng(seed), out = []; let x = x0;
  while (x < x1) {
    const w = wMin + r() * (wMax - wMin), h = hMin + Math.pow(r(), 1.6) * (hMax - hMin);
    out.push({ x, w, h, top: r() < 0.22 ? 'spire' : r() < 0.5 ? 'step' : 'flat', tank: r() < 0.28, seed: Math.floor(r() * 1e6) });
    x += w + (r() < 0.25 ? r() * 14 : -4);
  }
  return out;
}
function waterTower(x, y, s, fill) {
  ctx.fillStyle = fill; ctx.fillRect(x - 9 * s, y - 34 * s, 18 * s, 22 * s);
  poly([[x - 11 * s, y - 34 * s], [x, y - 46 * s], [x + 11 * s, y - 34 * s]], fill);
  ctx.strokeStyle = fill; ctx.lineWidth = 1.6 * s; ctx.beginPath(); ctx.moveTo(x - 8 * s, y - 12 * s); ctx.lineTo(x - 10 * s, y); ctx.moveTo(x + 8 * s, y - 12 * s); ctx.lineTo(x + 10 * s, y); ctx.moveTo(x - 9 * s, y - 2 * s); ctx.lineTo(x + 9 * s, y - 10 * s); ctx.stroke();
}
/** A row of buildings standing on `base`, their windows lit and slowly changing. `wake` 0..1 lights more of them. */
function drawBlock(list, t, { base, fill, dx = 0, win = NY.win, winA = 0.8, lit = 0.3, wake = 0, sx = 14, sy = 20, ww = 6, wh = 9 }) {
  list.forEach(b => {
    const x = b.x + dx, top = base - b.h;
    if (x > W + 50 || x + b.w < -50) return;
    ctx.fillStyle = fill; ctx.fillRect(x, top, b.w, b.h + 4);
    if (b.top === 'step') { ctx.fillRect(x + b.w * 0.18, top - 22, b.w * 0.64, 24); ctx.fillRect(x + b.w * 0.34, top - 40, b.w * 0.32, 20); }
    if (b.top === 'spire') { ctx.fillRect(x + b.w * 0.3, top - 30, b.w * 0.4, 32); ctx.fillRect(x + b.w / 2 - 1.5, top - 86, 3, 60); }
    if (b.tank && b.top !== 'spire') waterTower(x + b.w * (0.25 + 0.5 * hash(b.seed)), top - (b.top === 'step' ? 40 : 0), 0.9, fill);
    if (winA <= 0) return;
    const cols = Math.floor((b.w - 8) / sx), rows = Math.floor((b.h - 10) / sy), ox = x + (b.w - cols * sx) / 2 + (sx - ww) / 2;
    for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) {
      const hv = hash(b.seed + r * 37.3 + c * 101.9);
      if (hv > lit + wake * 0.5 + 0.05 * Math.sin(t * 0.5 + hv * 60)) continue;
      const warm = hash(b.seed * 1.7 + r * 11 + c * 5);
      ctx.fillStyle = `rgba(${warm > 0.82 ? '170,205,255' : win},${winA * (0.35 + 0.65 * hash(hv * 91))})`;
      ctx.fillRect(ox + c * sx, top + 10 + r * sy, ww, wh);
    }
  });
}
function empire(x, base, s, fill, lights = 1) {
  const tiers = [[62, 0, 300], [48, 300, 96], [36, 396, 70], [24, 466, 52], [12, 518, 44], [5, 562, 26]];
  ctx.fillStyle = fill; tiers.forEach(([hw, y0, h]) => ctx.fillRect(x - hw * s, base - (y0 + h) * s, hw * 2 * s, h * s + 2));
  ctx.fillRect(x - 1.5 * s, base - 680 * s, 3 * s, 100 * s);
  // lit ribs of windows, and the floodlit crown
  for (let i = -5; i <= 5; i++) { ctx.fillStyle = `rgba(${NY.win},${0.16 + 0.12 * hash(i + 9)})`; ctx.fillRect(x + i * 10 * s - 1.5 * s, base - 296 * s, 3 * s, 280 * s); }
  if (lights > 0) {
    const g = ctx.createLinearGradient(0, base - 590 * s, 0, base - 396 * s); g.addColorStop(0, `rgba(255,255,255,${0.9 * lights})`); g.addColorStop(1, `rgba(120,170,255,${0.05 * lights})`);
    ctx.fillStyle = g; ctx.fillRect(x - 36 * s, base - 466 * s, 72 * s, 70 * s); ctx.fillRect(x - 24 * s, base - 518 * s, 48 * s, 52 * s); ctx.fillRect(x - 12 * s, base - 562 * s, 24 * s, 44 * s);
    glowAt(x, base - 520 * s, 240 * s, '150,190,255', 0.35 * lights);
  }
}
function chrysler(x, base, s, fill, lights = 1) {
  ctx.fillStyle = fill; ctx.fillRect(x - 34 * s, base - 380 * s, 68 * s, 380 * s + 2); ctx.fillRect(x - 46 * s, base - 250 * s, 92 * s, 250 * s + 2);
  for (let i = 0; i < 6; i++) {   // the crown: arcs stepping in
    const w = (34 - i * 5) * s, y = base - (380 + i * 26) * s;
    ctx.beginPath(); ctx.ellipse(x, y, w, 34 * s, 0, Math.PI, 0); ctx.closePath(); ctx.fillStyle = fill; ctx.fill();
    if (lights > 0) { ctx.strokeStyle = `rgba(255,236,190,${0.75 * lights})`; ctx.lineWidth = 2 * s; ctx.beginPath(); ctx.ellipse(x, y, w * 0.72, 22 * s, 0, Math.PI * 1.12, Math.PI * 1.88); ctx.stroke(); }
  }
  poly([[x - 5 * s, base - 530 * s], [x, base - 660 * s], [x + 5 * s, base - 530 * s]], fill);
  if (lights > 0) glowAt(x, base - 450 * s, 170 * s, '255,225,170', 0.3 * lights);
}
/** The bridge: stone towers with their two pointed arches, the main cables, the suspenders and the fan of stays. */
function bridge(x1, x2, deck, th, fill, t, lights = 1) {
  const cable = (xa, ya, xb, yb, sag) => { ctx.beginPath(); for (let i = 0; i <= 40; i++) { const k = i / 40, x = lerp(xa, xb, k), y = lerp(ya, yb, k) + sag * 4 * k * (1 - k); i ? ctx.lineTo(x, y) : ctx.moveTo(x, y); } ctx.stroke(); };
  const top = deck - th, span = x2 - x1;
  ctx.strokeStyle = fill; ctx.lineWidth = 1.2;
  for (let x = x1 - span * 0.5; x <= x2 + span * 0.5; x += 12) {
    const inMid = x > x1 && x < x2, k = inMid ? (x - x1) / span : x <= x1 ? 1 - (x1 - x) / (span * 0.5) : 1 - (x - x2) / (span * 0.5);
    const y = inMid ? top + (th - 30) * 4 * k * (1 - k) : lerp(deck - 6, top, k) + 26 * 4 * k * (1 - k) * 0.4;
    ctx.beginPath(); ctx.moveTo(x, y); ctx.lineTo(x, deck); ctx.stroke();
  }
  [x1, x2].forEach(tx => { for (let i = 1; i <= 9; i++) { [-1, 1].forEach(d => { ctx.beginPath(); ctx.moveTo(tx, top + 8); ctx.lineTo(tx + d * i * span * 0.045, deck); ctx.stroke(); }); } });
  ctx.lineWidth = 3.5; cable(x1, top, x2, top, th - 30); cable(x1 - span * 0.5, deck - 6, x1, top, 10); cable(x2, top, x2 + span * 0.5, deck - 6, 10);
  ctx.fillStyle = fill; ctx.fillRect(x1 - span * 0.6, deck, span * 2.2, 9);
  [x1, x2].forEach(tx => {
    ctx.fillStyle = fill; ctx.fillRect(tx - 26, top - 10, 52, th + 70); ctx.fillRect(tx - 31, top - 16, 62, 10);
    ctx.fillStyle = 'rgba(40,50,110,0.9)';
    [-11, 11].forEach(d => { ctx.beginPath(); ctx.moveTo(tx + d - 7, deck - 4); ctx.lineTo(tx + d - 7, top + 60); ctx.quadraticCurveTo(tx + d, top + 30, tx + d + 7, top + 60); ctx.lineTo(tx + d + 7, deck - 4); ctx.closePath(); ctx.fill(); });
  });
  if (lights > 0) for (let i = 0; i <= 30; i++) {   // the necklace of lights on the main cable
    const k = i / 30, x = lerp(x1, x2, k), y = top + (th - 30) * 4 * k * (1 - k);
    ctx.fillStyle = `rgba(255,236,190,${lights * (0.55 + 0.45 * Math.sin(t * 2 + i * 1.7))})`; ctx.beginPath(); ctx.arc(x, y, 2.4, 0, Math.PI * 2); ctx.fill();
  }
}
const BLOCKS = { far: makeBlock(3, -200, W + 400, 120, 380, 46, 110), mid: makeBlock(8, -200, W + 400, 100, 330, 60, 150), near: makeBlock(21, -300, W + 500, 60, 230, 90, 210) };
function nightSky(top = NY.night0, bottom = NY.night1, haze = 0.5) {
  const g = ctx.createLinearGradient(0, 0, 0, H); g.addColorStop(0, top); g.addColorStop(0.72, bottom); g.addColorStop(1, NY.haze);
  ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
  if (haze > 0) { const h = ctx.createLinearGradient(0, 520, 0, 980); h.addColorStop(0, 'rgba(255,140,70,0)'); h.addColorStop(1, `rgba(255,140,70,${0.3 * haze})`); ctx.fillStyle = h; ctx.fillRect(0, 520, W, 460); }
}
/** The whole skyline over the river: three depths drifting past each other, the landmarks, their lights in the water. */
function skyline(t, { drift = 0, base = 880, wake = 0, lights = 1, water = true, dim = 0 } = {}) {
  nightSky();
  // clouds lit from under
  for (let i = 0; i < 7; i++) { const x = ((i * 380 + t * 9 + drift * 0.1) % (W + 700)) - 350, y = 150 + hash(i) * 260, r = 260 + hash(i + 3) * 200; const g = ctx.createRadialGradient(x, y, 0, x, y, r); g.addColorStop(0, 'rgba(120,110,190,0.16)'); g.addColorStop(1, 'rgba(120,110,190,0)'); ctx.fillStyle = g; ctx.fillRect(x - r, y - r * 0.5, r * 2, r); }
  drawBlock(BLOCKS.far, t, { base, fill: '#232a66', dx: -drift * 0.25, winA: 0.5, lit: 0.34, wake, sx: 10, sy: 13, ww: 3.5, wh: 5 });
  chrysler(1560 - drift * 0.3, base, 1.0, '#1e245c', lights);
  empire(1150 - drift * 0.3, base, 1.1, '#1e245c', lights);
  drawBlock(BLOCKS.mid, t, { base, fill: '#12163c', dx: -drift * 0.55, winA: 0.85, lit: 0.3, wake });
  bridge(170 - drift * 0.7, 700 - drift * 0.7, base - 150, 290, '#0d1030', t, lights);
  drawBlock(BLOCKS.near, t, { base: base + 6, fill: '#090b22', dx: -drift, winA: 0.95, lit: 0.22, wake, sx: 18, sy: 24, ww: 8, wh: 12 });
  if (water) {
    const g = ctx.createLinearGradient(0, base, 0, H); g.addColorStop(0, '#0a0d2b'); g.addColorStop(1, '#03040d'); ctx.fillStyle = g; ctx.fillRect(0, base + 4, W, H - base);
    const r = rng(31);
    for (let i = 0; i < 150; i++) {   // lights lying on the river
      const x = r() * W, len = 20 + r() * 110, w = 2 + r() * 5, sh = Math.sin(t * (1 + r() * 2) + i) * 4, cool = r() > 0.8;
      const lg = ctx.createLinearGradient(0, base + 6, 0, base + 6 + len); lg.addColorStop(0, `rgba(${cool ? '170,205,255' : NY.win},${0.5 * (0.4 + 0.6 * r())})`); lg.addColorStop(1, `rgba(${NY.win},0)`);
      ctx.fillStyle = lg; ctx.fillRect(x + sh, base + 6, w, len);
    }
  }
  if (dim > 0) { ctx.fillStyle = `rgba(3,4,12,${dim})`; ctx.fillRect(0, 0, W, H); }
}

// ---------- people ----------
/** A figure, `h` tall, feet at (x, y). `o`: dir (1 faces right), walk (phase, or null to stand), stride, lean, coat,
 *  legs, skin, hair {style: bob | long | bun | short, color}, hat, flare (the cut of the coat), arm ('down', 'watch',
 *  'hold', 'reach', 'pump', 'none'), bouquet, cane, bag, tails (a coat flying behind a runner), breathe (phase). */
function figure(x, y, h, o = {}) {
  const { dir = 1, walk = null, stride = 1, lean = 0, coat = '#1b1d3a', legs = '#0c0d1c', skin = '#e8b891', hair = null, hat = false, flare = 0, arm = 'down', bouquet = false,
    cane = false, bag = false, tails = 0, breathe = null, nod = 0 } = o;
  const u = h / 100, ph = walk == null ? 0 : walk, sw = walk == null ? 0 : stride;
  ctx.save(); ctx.translate(x, y); ctx.scale(u * dir, u); ctx.rotate(lean);
  ctx.lineCap = 'round'; ctx.lineJoin = 'round';
  const bob = walk == null ? (breathe == null ? 0 : Math.sin(breathe) * 0.6) : -Math.abs(Math.sin(ph)) * 1.6 * sw;
  ctx.translate(0, bob);
  // legs
  [0, Math.PI].forEach((off, i) => {
    const a = Math.sin(ph + off) * 0.46 * sw, knee = Math.max(0, Math.cos(ph + off)) * 0.5 * sw;
    const kx = Math.sin(a) * 24, ky = -48 + Math.cos(a) * 24, fx = kx + Math.sin(a - knee) * 24, fy = ky + Math.cos(a - knee) * 24;
    ctx.strokeStyle = legs; ctx.lineWidth = 7; ctx.beginPath(); ctx.moveTo(i ? 2 : -2, -48); ctx.lineTo(kx, ky); ctx.lineTo(fx, Math.min(fy, -1 - bob)); ctx.stroke();
    ctx.lineWidth = 4.5; ctx.beginPath(); ctx.moveTo(fx, Math.min(fy, -1.5 - bob)); ctx.lineTo(fx + 5, Math.min(fy, -1.5 - bob)); ctx.stroke();
  });
  // the back arm, behind the coat
  const armTo = (hx, hy, ex, ey, w = 5.4) => { ctx.strokeStyle = coat; ctx.lineWidth = w; ctx.beginPath(); ctx.moveTo(1, -79); ctx.lineTo(ex, ey); ctx.lineTo(hx, hy); ctx.stroke(); ctx.fillStyle = skin; ctx.beginPath(); ctx.arc(hx, hy, 2.6, 0, Math.PI * 2); ctx.fill(); };
  const swing = Math.sin(ph) * 0.5 * sw;
  if (arm === 'pump') armTo(Math.sin(swing) * 10 + 9, -64 - Math.cos(swing) * 6, Math.sin(-swing) * 12 - 3, -66);
  else if (arm !== 'reach' && arm !== 'none') armTo(Math.sin(swing) * 16, -48 + (1 - Math.cos(swing)) * 6, Math.sin(swing) * 8, -64);
  // coat
  const hem = -38 + (flare ? 6 : 0), hw = 10 + flare * 8, sway = Math.sin(ph * 2) * 1.2 * sw;
  if (tails > 0) poly([[-8, -70], [-10 - 26 * tails, -40 + 6 * Math.sin(ph * 2)], [-6, hem]], coat);
  ctx.fillStyle = coat; ctx.beginPath(); ctx.moveTo(-10, -82); ctx.quadraticCurveTo(0, -87, 10, -82); ctx.lineTo(9, -60); ctx.lineTo(hw + sway, hem); ctx.lineTo(-hw + sway, hem); ctx.lineTo(-9, -60); ctx.closePath(); ctx.fill();
  // head
  ctx.save(); ctx.translate(1.5, -91); ctx.rotate(nod);
  if (hair && (hair.style === 'long' || hair.style === 'bob')) { ctx.fillStyle = hair.color; ctx.beginPath(); ctx.ellipse(-1.8, 0.5, 8.6, 9, 0, 0, Math.PI * 2); ctx.fill(); ctx.fillRect(-10.4, 0, hair.style === 'long' ? 9 : 7, hair.style === 'long' ? 20 : 9); }
  ctx.fillStyle = skin; ctx.beginPath(); ctx.arc(0, 0, 7.4, 0, Math.PI * 2); ctx.fill();
  if (hair) {
    ctx.fillStyle = hair.color;
    if (hair.style === 'short') { ctx.beginPath(); ctx.arc(-0.6, -1.2, 7.8, Math.PI * 0.95, Math.PI * 1.95); ctx.closePath(); ctx.fill(); }
    if (hair.style === 'bun') { ctx.beginPath(); ctx.arc(-0.8, -1.4, 7.9, Math.PI * 0.8, Math.PI * 1.9); ctx.closePath(); ctx.fill(); ctx.beginPath(); ctx.arc(-7.6, -4.6, 4, 0, Math.PI * 2); ctx.fill(); }
    if (hair.style === 'long' || hair.style === 'bob') { ctx.beginPath(); ctx.arc(-0.8, -1.6, 7.9, Math.PI * 0.9, Math.PI * 1.85); ctx.closePath(); ctx.fill(); }
  }
  if (hat) { ctx.fillStyle = typeof hat === 'string' ? hat : '#14152b'; ctx.beginPath(); ctx.ellipse(0.5, -5.2, 12, 2.6, -0.06, 0, Math.PI * 2); ctx.fill(); ctx.beginPath(); ctx.roundRect(-6.6, -13.4, 13.2, 9, 3.4); ctx.fill(); }
  ctx.restore();
  // the front arm, and what it holds
  if (arm === 'watch') { armTo(11, -77, 9, -63); }
  else if (arm === 'hold') { armTo(13, -62, 4, -62); }
  else if (arm === 'reach') { armTo(20, -76, 10, -70, 5.8); armTo(18, -66, 8, -62, 5.8); }
  else if (arm === 'pump') armTo(Math.sin(-swing) * 10 + 9, -64 - Math.cos(swing) * 6, Math.sin(swing) * 12 - 3, -66);
  else if (arm !== 'none') armTo(Math.sin(-swing) * 16, -48 + (1 - Math.cos(swing)) * 6, Math.sin(-swing) * 8, -64);
  if (bouquet) {
    const bx = arm === 'hold' ? 15 : Math.sin(-swing) * 16 + 2, by = arm === 'hold' ? -66 : -50;
    poly([[bx - 2, by + 9], [bx + 3, by + 9], [bx + 9, by - 6], [bx - 7, by - 6]], '#e9e2d0');
    [[0, -10], [-6, -7], [6, -8], [-2, -15], [4, -14], [9, -12], [-8, -12]].forEach(([dx, dy], i) => { ctx.fillStyle = i % 3 === 2 ? '#ff6b5e' : NY.red; ctx.beginPath(); ctx.arc(bx + dx, by + dy, 3.6, 0, Math.PI * 2); ctx.fill(); });
  }
  if (cane) { ctx.strokeStyle = '#3a2a1c'; ctx.lineWidth = 1.8; const hx = Math.sin(swing) * 16; ctx.beginPath(); ctx.moveTo(hx, -48); ctx.lineTo(hx + 4, -1 - bob); ctx.stroke(); }
  if (bag) { ctx.fillStyle = typeof bag === 'string' ? bag : '#2a1c14'; ctx.beginPath(); ctx.roundRect(Math.sin(swing) * 16 - 5, -46, 10, 12, 2); ctx.fill(); }
  ctx.restore();
}
/** A figure with its shadow on a polished floor. */
function standing(x, y, h, o, shine = 0.16) {
  ctx.save(); ctx.globalAlpha *= shine; ctx.translate(x, y); ctx.scale(1, -0.7); ctx.translate(-x, -y); figure(x, y, h, o); ctx.restore();
  ctx.save(); ctx.fillStyle = 'rgba(0,0,0,0.35)'; ctx.beginPath(); ctx.ellipse(x, y + 2, h * 0.16, h * 0.03, 0, 0, Math.PI * 2); ctx.fill(); ctx.restore();
  figure(x, y, h, o);
}
/** Two people holding each other, feet at (x, y), `h` tall. `k` 0..1 closes the arms: his around her waist, hers
 *  around his neck, their heads together. */
function embrace(x, y, h, her, him, k = 1, t = 0, shine = 0.2) {
  const u = h / 100, hx = x - 12 * u, mx = x + 12 * u, e = easeInOut(clamp(k));
  standing(mx, y, h * 1.05, { ...him, dir: -1, arm: 'none', lean: 0.05 * e, nod: 0.26 * e, breathe: t * 2.6, bouquet: false, cane: false }, shine);
  standing(hx, y, h, { ...her, dir: 1, arm: 'none', lean: 0.05 * e, nod: 0.22 * e, breathe: t * 2.6 + 1, bag: false }, shine);
  const arm = (pts, color, skin, w) => {
    ctx.save(); ctx.lineCap = 'round'; ctx.lineJoin = 'round'; ctx.strokeStyle = 'rgba(0,0,0,0.22)'; ctx.lineWidth = (w + 1.6) * u;
    const path = () => { ctx.beginPath(); pts.forEach(([px, py], i) => (i ? ctx.lineTo(x + px * u, y + py * u) : ctx.moveTo(x + px * u, y + py * u))); };
    path(); ctx.stroke(); ctx.strokeStyle = color; ctx.lineWidth = w * u; path(); ctx.stroke();
    const [ex, ey] = pts[pts.length - 1]; ctx.fillStyle = skin; ctx.beginPath(); ctx.arc(x + ex * u, y + ey * u, 2.9 * u, 0, Math.PI * 2); ctx.fill(); ctx.restore();
  };
  const L2 = (a, b) => [lerp(a[0], b[0], e), lerp(a[1], b[1], e)];
  arm([[9, -82], L2([12, -66], [0, -66]), L2([12, -50], [-17, -60])], him.coat, him.skin, 5.8);   // his arm around her waist
  arm([[-9, -79], L2([-12, -64], [2, -84]), L2([-12, -48], [15, -88])], her.coat, her.skin, 5.4);   // hers around his neck
}
/** Head and shoulders, close: a face at a train window. (x, y) is the base of the neck, the head about 130 * s tall.
 *  `o`: coat, skin, hair, grey (lighter hair at the temple), hat, collar, scarf, nod, worry 0..1, dir. */
function bust(x, y, s, o = {}) {
  const { dir = 1, coat = '#d4a868', skin = '#e4b28c', hair = '#22150e', hat = null, collar = '#efe6d2', scarf = null, nod = 0, worry = 0.6 } = o;
  const dark = (c, k) => mix(c, '#000000', k);
  ctx.save(); ctx.translate(x, y); ctx.scale(s * dir, s); ctx.lineCap = 'round'; ctx.lineJoin = 'round';
  ctx.fillStyle = coat; ctx.beginPath(); ctx.moveTo(-170, 420); ctx.lineTo(-150, 70); ctx.quadraticCurveTo(-140, 12, -56, -8); ctx.lineTo(60, -8); ctx.quadraticCurveTo(140, 12, 150, 70); ctx.lineTo(170, 420); ctx.closePath(); ctx.fill();
  ctx.fillStyle = dark(coat, 0.16); ctx.beginPath(); ctx.moveTo(-170, 420); ctx.lineTo(-150, 70); ctx.quadraticCurveTo(-142, 24, -100, 6); ctx.lineTo(-90, 420); ctx.closePath(); ctx.fill();   // the far shoulder in shadow
  if (scarf) { ctx.fillStyle = scarf; ctx.beginPath(); ctx.roundRect(-48, -30, 104, 46, 20); ctx.fill(); ctx.beginPath(); ctx.roundRect(6, -6, 40, 150, 10); ctx.fill(); }
  else { poly([[-34, -12], [40, -12], [8, 96]], collar); poly([[-8, -4], [20, -4], [10, 60], [4, 60]], '#5a1f1c'); }
  poly([[-60, -10], [-34, -14], [8, 100], [-22, 170]], dark(coat, 0.1)); poly([[64, -10], [40, -14], [8, 100], [36, 170]], dark(coat, 0.1));
  ctx.fillStyle = dark(skin, 0.14); ctx.fillRect(-22, -56, 48, 52);
  ctx.translate(6, -104); ctx.rotate(nod);
  ctx.fillStyle = skin; ctx.beginPath(); ctx.ellipse(0, 0, 54, 64, 0, 0, Math.PI * 2); ctx.fill();
  ctx.beginPath(); ctx.moveTo(46, -10); ctx.quadraticCurveTo(74, 16, 48, 24); ctx.closePath(); ctx.fill();   // the nose
  ctx.fillStyle = dark(skin, 0.14); ctx.beginPath(); ctx.ellipse(-26, 6, 9, 15, 0, 0, Math.PI * 2); ctx.fill();   // the ear
  ctx.strokeStyle = dark(skin, 0.72); ctx.lineWidth = 4; ctx.beginPath(); ctx.arc(26, -10, 10, Math.PI * 0.12, Math.PI * 0.88); ctx.stroke();   // an eye, lowered
  ctx.lineWidth = 5; ctx.beginPath(); ctx.moveTo(10, -30 - worry * 8); ctx.quadraticCurveTo(26, -36, 42, -28 + worry * 2); ctx.stroke();   // the brow
  ctx.lineWidth = 3.5; ctx.beginPath(); ctx.moveTo(24, 38); ctx.quadraticCurveTo(34, 38 - worry * 3, 44, 38 + worry * 3); ctx.stroke();   // the mouth
  ctx.fillStyle = hair; ctx.beginPath(); ctx.moveTo(-56, 14); ctx.quadraticCurveTo(-70, -74, 2, -72); ctx.quadraticCurveTo(54, -70, 55, -24); ctx.quadraticCurveTo(22, -50, -14, -36); ctx.quadraticCurveTo(-34, -18, -36, 16); ctx.closePath(); ctx.fill();
  if (hat) {
    ctx.fillStyle = hat; ctx.beginPath(); ctx.ellipse(4, -42, 96, 15, -0.04, 0, Math.PI * 2); ctx.fill(); ctx.beginPath(); ctx.roundRect(-52, -122, 110, 82, [30, 34, 6, 6]); ctx.fill();
    ctx.fillStyle = dark(hat, 0.45); ctx.fillRect(-52, -62, 110, 16);
  }
  ctx.restore();
}
/** Passers-by. `t` is their own clock (run it fast and the evening goes by), `density` 0..1 is how many of them are
 *  still here, `smear` 0..1 drags them out like a long exposure, `gap` [x0, x1] keeps a clearing they walk around. */
function crowd(t, { n = 40, seed = 5, density = 1, smear = 0, yMin = 790, yMax = 900, hMin = 130, hMax = 190, tint = '#15152e', haze = null, alpha = 0.9, gap = null, shine = 0.12 } = {}) {
  const r = rng(seed), list = [];
  for (let i = 0; i < n; i++) {
    const d = r(), dir = r() < 0.5 ? 1 : -1, v = (70 + r() * 80) * (0.7 + d * 0.5), x0 = r() * (W + 500), thr = r(), ph = r() * 6, hatted = r() < 0.3, bagged = r() < 0.4;
    const a = clamp((density - thr) * 6);
    if (a <= 0) continue;
    const x = ((x0 + dir * v * t) % (W + 500) + W + 500) % (W + 500) - 250;
    let y = lerp(yMin, yMax, d);
    if (gap && x > gap[0] && x < gap[1]) y += (d < 0.5 ? -1 : 1) * 26 * Math.sin(Math.PI * (x - gap[0]) / (gap[1] - gap[0]));
    list.push({ x, y, h: lerp(hMin, hMax, d), dir, a, ph: ph + t * v / 22, hatted, bagged, v, d });
  }
  list.sort((p, q) => p.y - q.y).forEach(p => {
    const c = haze ? mix(haze, tint, 0.35 + 0.65 * p.d) : tint, o = { dir: p.dir, walk: p.ph, coat: c, legs: c, skin: c, hat: p.hatted ? c : false, bag: p.bagged ? c : false };
    ctx.save(); ctx.globalAlpha *= alpha * p.a * (haze ? 1 : 0.55 + 0.45 * p.d);
    if (smear > 0.05) for (let g = 3; g > 0; g--) { ctx.save(); ctx.globalAlpha *= 0.24; figure(p.x - p.dir * g * p.v * smear * 0.22, p.y, p.h, o); ctx.restore(); }
    if (shine > 0) { ctx.save(); ctx.globalAlpha *= shine; ctx.translate(p.x, p.y); ctx.scale(1, -0.7); ctx.translate(-p.x, -p.y); figure(p.x, p.y, p.h, o); ctx.restore(); }
    figure(p.x, p.y, p.h, o);
    ctx.restore();
  });
}

// ---------- the concourse, and its clock ----------
const HALLX = 1300, FLOOR = 770;
function ballClock(x, y, r, minutes, glow = 1) {
  glowAt(x, y, r * 5, '255,214,140', 0.4 * glow);
  ctx.save(); ctx.translate(x, y);
  ctx.fillStyle = NY.brass; ctx.beginPath(); ctx.ellipse(0, 0, r * 1.22, r * 1.16, 0, 0, Math.PI * 2); ctx.fill();
  poly([[-r * 0.2, -r * 1.1], [0, -r * 1.75], [r * 0.2, -r * 1.1]], NY.brass); ctx.beginPath(); ctx.arc(0, -r * 1.34, r * 0.2, 0, Math.PI * 2); ctx.fill();
  const g = ctx.createRadialGradient(0, 0, 0, 0, 0, r); g.addColorStop(0, '#fffdf0'); g.addColorStop(1, '#ffeab0');
  ctx.fillStyle = g; ctx.beginPath(); ctx.arc(0, 0, r, 0, Math.PI * 2); ctx.fill();
  ctx.fillStyle = '#7a5a26'; for (let i = 0; i < 12; i++) { const a = i / 12 * Math.PI * 2; ctx.beginPath(); ctx.arc(Math.sin(a) * r * 0.8, -Math.cos(a) * r * 0.8, r * (i % 3 ? 0.035 : 0.06), 0, Math.PI * 2); ctx.fill(); }
  ctx.strokeStyle = '#3a1a22'; ctx.lineCap = 'round';
  const hA = (minutes / 720) * Math.PI * 2, mA = (minutes / 60) * Math.PI * 2;
  ctx.lineWidth = r * 0.11; ctx.beginPath(); ctx.moveTo(0, 0); ctx.lineTo(Math.sin(hA) * r * 0.48, -Math.cos(hA) * r * 0.48); ctx.stroke();
  ctx.lineWidth = r * 0.07; ctx.beginPath(); ctx.moveTo(0, 0); ctx.lineTo(Math.sin(mA) * r * 0.76, -Math.cos(mA) * r * 0.76); ctx.stroke();
  ctx.fillStyle = '#3a1a22'; ctx.beginPath(); ctx.arc(0, 0, r * 0.08, 0, Math.PI * 2); ctx.fill();
  ctx.restore();
}
const STARS = (() => { const r = rng(88), out = []; for (let i = 0; i < 520; i++) out.push([-200 + r() * (W + 400), -1250 + r() * 1290, 0.7 + Math.pow(r(), 3) * 4.2, r() * 6]); return out; })();
const FIGURES = (() => {   // the painted constellations: short chains of stars
  const r = rng(131), out = [];
  for (let i = 0; i < 16; i++) { let x = r() * W, y = -1150 + r() * 1050; const pts = [[x, y]]; for (let k = 0; k < 3 + Math.floor(r() * 4); k++) { x += (r() - 0.4) * 190; y += (r() - 0.5) * 150; pts.push([x, y]); } out.push(pts); }
  return out;
})();
/** The hall. `day` 1..0 is the light through the windows (gold shafts falling to dusk), `night` picks tonight's blue
 *  and gold, `minutes` sets the clock. Draw people after it, then call hallLight for the air in front of them. */
function concourse(t, { day = 1, night = false, minutes = 420, glow = 1 } = {}) {
  const wall0 = night ? '#262a5c' : '#8a6238', wall1 = night ? '#12143a' : '#3d2917', stone = night ? '#1b1e48' : '#5e4226';
  const g = ctx.createLinearGradient(0, 60, 0, FLOOR); g.addColorStop(0, wall0); g.addColorStop(1, wall1); ctx.fillStyle = g; ctx.fillRect(-400, -100, W + 800, FLOOR + 100);
  // the vault, with its stars
  const v = ctx.createLinearGradient(0, -1200, 0, 110); v.addColorStop(0, '#0c3a40'); v.addColorStop(1, night ? '#1a5a60' : '#4a6a52'); ctx.fillStyle = v; ctx.fillRect(-400, -1300, W + 800, 1400);
  ctx.strokeStyle = 'rgba(242,193,78,0.2)'; ctx.lineWidth = 3; [[-2600, 2300], [-3300, 2700]].forEach(([cy, r]) => { ctx.beginPath(); ctx.arc(960, cy, r, 0, Math.PI * 2); ctx.stroke(); });   // the gold bands across the sky
  ctx.strokeStyle = 'rgba(255,224,150,0.22)'; ctx.lineWidth = 1.6; FIGURES.forEach(pts => { ctx.beginPath(); pts.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y))); ctx.stroke(); pts.forEach(([x, y]) => { ctx.fillStyle = 'rgba(255,232,170,0.9)'; ctx.beginPath(); ctx.arc(x, y, 3.2, 0, Math.PI * 2); ctx.fill(); }); });
  STARS.forEach(([x, y, s, p]) => { const tw = 0.45 + 0.4 * Math.sin(t * 1.4 + p); if (s > 3) glowAt(x, y, s * 6, '255,224,150', 0.35 * tw); ctx.fillStyle = `rgba(255,224,150,${tw})`; ctx.beginPath(); ctx.arc(x, y, s, 0, Math.PI * 2); ctx.fill(); });
  const up = ctx.createLinearGradient(0, -260, 0, 100); up.addColorStop(0, 'rgba(255,214,140,0)'); up.addColorStop(1, `rgba(255,214,140,${night ? 0.16 : 0.1})`); ctx.fillStyle = up; ctx.fillRect(-400, -260, W + 800, 360);   // the hall's light on the edge of the vault
  ctx.fillStyle = stone; ctx.fillRect(-400, 96, W + 800, 22);
  // three great windows
  const sky = night ? [70, 90, 190] : [Math.round(lerp(60, 255, day)), Math.round(lerp(80, 214, day)), Math.round(lerp(170, 140, day))];
  [-330, 0, 330].forEach(dx => {
    const x = HALLX + dx, wg = ctx.createLinearGradient(0, 140, 0, 470); wg.addColorStop(0, `rgba(${sky},${night ? 0.5 : 0.55 + 0.4 * day})`); wg.addColorStop(1, `rgba(${sky},${night ? 0.2 : 0.25 + 0.3 * day})`);
    ctx.beginPath(); ctx.roundRect(x - 105, 140, 210, 330, [105, 105, 0, 0]); ctx.fillStyle = wg; ctx.fill();
    ctx.strokeStyle = stone; ctx.lineWidth = 5; ctx.beginPath();
    [-52, 0, 52].forEach(m => { ctx.moveTo(x + m, 140); ctx.lineTo(x + m, 470); }); [230, 310, 390].forEach(m => { ctx.moveTo(x - 105, m); ctx.lineTo(x + 105, m); }); ctx.stroke();
    ctx.lineWidth = 12; ctx.beginPath(); ctx.roundRect(x - 105, 140, 210, 332, [105, 105, 0, 0]); ctx.stroke();
  });
  // the balcony, the departures board, the lamps
  ctx.fillStyle = stone; ctx.fillRect(-400, 486, W + 800, 16); ctx.fillRect(-400, 536, W + 800, 10);
  for (let x = -390; x < W + 400; x += 22) ctx.fillRect(x, 500, 7, 38);
  ctx.fillStyle = night ? '#090a1c' : '#1e140c'; ctx.fillRect(1560, 586, 440, 92);
  for (let i = 0; i < 5; i++) for (let j = 0; j < 8; j++) { ctx.fillStyle = `rgba(255,190,90,${0.25 + 0.5 * hash(i * 13 + j * 7 + Math.floor(t * 0.7 + j * 0.3))})`; ctx.fillRect(1576 + j * 53, 598 + i * 15, 30 + hash(i + j * 3) * 16, 5); }
  [420, 900, 1510].forEach((x, i) => { glowAt(x, 610, 150, '255,200,120', (night ? 0.3 : 0.14) * glow); ctx.fillStyle = '#ffe2a6'; ctx.beginPath(); ctx.arc(x, 610, 9, 0, Math.PI * 2); ctx.fill(); ctx.fillStyle = stone; ctx.fillRect(x - 2, 546, 4, 56); });
  // the floor, holding the light
  const f = ctx.createLinearGradient(0, FLOOR, 0, H + 200); f.addColorStop(0, night ? '#2a2c5e' : '#8c6a40'); f.addColorStop(0.25, night ? '#12143a' : '#3a2616'); f.addColorStop(1, '#05050c'); ctx.fillStyle = f; ctx.fillRect(-400, FLOOR, W + 800, H);
  [-330, 0, 330].forEach(dx => { const x = HALLX + dx - 130, rg = ctx.createLinearGradient(0, FLOOR, 0, FLOOR + 300); rg.addColorStop(0, `rgba(${sky},${night ? 0.1 : 0.06 + 0.24 * day})`); rg.addColorStop(1, `rgba(${sky},0)`); ctx.fillStyle = rg; ctx.fillRect(x - 90, FLOOR, 180, 300); });
  if (!night && day < 1) { ctx.fillStyle = `rgba(9,9,34,${0.62 * (1 - day)})`; ctx.fillRect(-400, -1300, W + 800, H + 1700); }   // dusk in the hall; the booth keeps its light
  // the information booth, and the clock on top of it
  glowAt(HALLX, FLOOR + 40, 420, '255,205,130', 0.22 * glow);
  ctx.fillStyle = night ? '#2a2413' : '#3a2a14'; ctx.beginPath(); ctx.roundRect(HALLX - 150, 640, 300, 160, 16); ctx.fill();
  for (let i = 0; i < 5; i++) { const wx = HALLX - 128 + i * 54, lg = ctx.createLinearGradient(0, 664, 0, 754); lg.addColorStop(0, `rgba(255,226,160,${0.95 * glow})`); lg.addColorStop(1, `rgba(255,170,80,${0.6 * glow})`); ctx.fillStyle = lg; ctx.beginPath(); ctx.roundRect(wx, 664, 40, 88, 5); ctx.fill(); }
  ctx.fillStyle = NY.brass; ctx.beginPath(); ctx.roundRect(HALLX - 164, 626, 328, 20, 8); ctx.fill(); ctx.beginPath(); ctx.roundRect(HALLX - 158, 756, 316, 12, 5); ctx.fill();
  poly([[HALLX - 34, 626], [HALLX - 16, 590], [HALLX + 16, 590], [HALLX + 34, 626]], NY.brass); ctx.fillRect(HALLX - 9, 566, 18, 26);
  ballClock(HALLX, 520, 46, minutes, glow);
  const rf = ctx.createLinearGradient(0, 800, 0, 1000); rf.addColorStop(0, `rgba(255,214,140,${0.3 * glow})`); rf.addColorStop(1, 'rgba(255,214,140,0)'); ctx.fillStyle = rf; ctx.fillRect(HALLX - 150, 800, 300, 200);
}
/** The air of the hall, in front of the people: shafts of daylight with dust turning in them, or tonight's haze. */
function hallLight(t, { day = 1, night = false } = {}) {
  ctx.save(); ctx.globalCompositeOperation = 'lighter';
  if (!night && day > 0.02) [-330, 0, 330].forEach((dx, i) => {
    const x = HALLX + dx, g = ctx.createLinearGradient(x, 200, x - 520, FLOOR + 160); g.addColorStop(0, `rgba(255,206,120,${0.34 * day})`); g.addColorStop(1, 'rgba(255,206,120,0)');
    ctx.beginPath(); ctx.moveTo(x - 100, 150); ctx.lineTo(x + 100, 150); ctx.lineTo(x - 330, FLOOR + 190); ctx.lineTo(x - 700, FLOOR + 190); ctx.closePath(); ctx.fillStyle = g; ctx.fill();
    const r = rng(40 + i);
    for (let k = 0; k < 46; k++) { const f = r(), px = x - f * 520 + (r() - 0.5) * 180 + Math.sin(t * 0.4 + k) * 14, py = 190 + f * 620 + Math.cos(t * 0.3 + k * 2) * 12; ctx.fillStyle = `rgba(255,236,190,${day * 0.5 * (0.3 + 0.7 * Math.abs(Math.sin(t * 0.9 + k * 1.7)))})`; ctx.beginPath(); ctx.arc(px, py, 1 + r() * 1.6, 0, Math.PI * 2); ctx.fill(); }
  });
  ctx.restore();
}

// ---------- the subway ----------
/** One car seen from the side, `len` long, floor at y. era 'red' (1986) or 'steel'. `lit` 0..1 is its lights,
 *  `door` 0..1 how far its doors stand open, `riders` puts people at the windows. */
function subwayCar(x, y, len, { era = 'steel', lit = 1, door = 0, riders = 9, bullet = '6', seed = 1 } = {}) {
  const h = len * 0.34, top = y - h, body = era === 'red' ? NY.redbird : '#8f9aa9';
  ctx.fillStyle = '#07080f'; ctx.fillRect(x + len * 0.05, y, len * 0.9, h * 0.16);
  [0.14, 0.24, 0.76, 0.86].forEach(k => { ctx.fillStyle = '#0d0f19'; ctx.beginPath(); ctx.arc(x + len * k, y + h * 0.17, h * 0.1, 0, Math.PI * 2); ctx.fill(); ctx.fillStyle = '#2a2e3a'; ctx.beginPath(); ctx.arc(x + len * k, y + h * 0.17, h * 0.04, 0, Math.PI * 2); ctx.fill(); });
  const g = ctx.createLinearGradient(0, top, 0, y);
  if (era === 'red') { g.addColorStop(0, '#5b1512'); g.addColorStop(0.2, '#9c2a22'); g.addColorStop(1, '#5e1713'); } else { g.addColorStop(0, '#5d6878'); g.addColorStop(0.18, '#c5cfdb'); g.addColorStop(0.6, '#95a0b0'); g.addColorStop(1, '#4e5767'); }
  ctx.fillStyle = g; ctx.beginPath(); ctx.roundRect(x, top, len, h, [h * 0.14, h * 0.14, 4, 4]); ctx.fill();
  if (era === 'steel') { ctx.strokeStyle = 'rgba(40,48,62,0.35)'; ctx.lineWidth = 1.2; for (let i = 0; i < 7; i++) { const yy = y - h * (0.05 + i * 0.045); ctx.beginPath(); ctx.moveTo(x + 4, yy); ctx.lineTo(x + len - 4, yy); ctx.stroke(); } }
  else { ctx.fillStyle = 'rgba(20,6,5,0.5)'; ctx.fillRect(x, top + h * 0.2, len, h * 0.46); ctx.fillStyle = 'rgba(240,220,180,0.5)'; ctx.fillRect(x, top + h * 0.7, len, h * 0.018); ctx.fillStyle = 'rgba(0,0,0,0.25)'; ctx.fillRect(x, top + h * 0.86, len, h * 0.14); }
  const wy = top + h * 0.24, wh = h * 0.38, glowC = `rgba(255,${era === 'red' ? 196 : 226},${era === 'red' ? 120 : 170},`;
  const r = rng(seed * 9 + 2);
  const pane = (px, pw, isDoor) => {
    ctx.fillStyle = '#0b0c14'; ctx.beginPath(); ctx.roundRect(px - 2, wy - 2, pw + 4, wh + 4, 5); ctx.fill();
    ctx.fillStyle = glowC + (0.12 + 0.83 * lit) + ')'; ctx.beginPath(); ctx.roundRect(px, wy, pw, wh, 4); ctx.fill();
    if (!isDoor && r() < riders / 12) {
      const hx = px + pw * (0.3 + r() * 0.4), hr = wh * 0.19;
      ctx.save(); ctx.beginPath(); ctx.roundRect(px, wy, pw, wh, 4); ctx.clip();
      ctx.fillStyle = 'rgba(12,12,24,0.92)'; ctx.beginPath(); ctx.arc(hx, wy + wh * 0.52, hr, 0, Math.PI * 2); ctx.fill(); ctx.beginPath(); ctx.roundRect(hx - hr * 1.7, wy + wh * 0.7, hr * 3.4, wh * 0.4, hr); ctx.fill();
      ctx.restore();
    }
  };
  ctx.save(); ctx.beginPath(); ctx.rect(x, top, len, h); ctx.clip();
  const doors = [0.14, 0.38, 0.62, 0.86];
  doors.forEach(k => {
    const dx = x + len * k, dw = len * 0.085, open = door * dw * 0.48;
    if (door > 0) { ctx.fillStyle = glowC + (0.9 * lit) + ')'; ctx.fillRect(dx - dw / 2, top + h * 0.1, dw, h * 0.9); }
    ctx.fillStyle = era === 'red' ? '#7a1d18' : '#a9b3c1';
    ctx.fillRect(dx - dw / 2 - open, top + h * 0.1, dw / 2 - 1, h * 0.9); ctx.fillRect(dx + 1 + open, top + h * 0.1, dw / 2 - 1, h * 0.9);
    pane(dx - dw / 2 + 4 - open, dw / 2 - 9, true); pane(dx + 5 + open, dw / 2 - 9, true);
  });
  for (let i = 0; i < doors.length - 1; i++) { const a = x + len * doors[i] + len * 0.055, b = x + len * doors[i + 1] - len * 0.055, pw = (b - a - 8) / 2; pane(a, pw); pane(a + pw + 8, pw); }
  pane(x + len * 0.02, len * 0.05); pane(x + len * 0.93, len * 0.05);
  ctx.restore();
  if (bullet) { const bx = x + len * 0.26, by = top + h * 0.13; ctx.fillStyle = L[bullet] || '#333'; ctx.beginPath(); ctx.arc(bx, by, h * 0.06, 0, Math.PI * 2); ctx.fill(); text(bullet, bx, by + 1, { size: h * 0.085, weight: 800, color: 'NQR'.includes(bullet) ? '#111' : '#fff', align: 'center', base: 'middle', display: false }); }
  if (lit > 0.2) { const lg = ctx.createLinearGradient(0, y, 0, y + h * 0.5); lg.addColorStop(0, glowC + 0.18 * lit + ')'); lg.addColorStop(1, glowC + '0)'); ctx.fillStyle = lg; ctx.fillRect(x, y + h * 0.14, len, h * 0.4); }
}
/** The tunnel going by behind the train: ribs, lamps that smear with speed, cable runs, the track bed. `pos` is how
 *  far the train has travelled (px), `v` its speed (px/s). */
function tunnel(t, pos, v, { y = 700, tint = '10,14,34', lamp = '190,215,255', old = false } = {}) {
  const g = ctx.createLinearGradient(0, 0, 0, H); g.addColorStop(0, old ? '#0d0906' : '#04050d'); g.addColorStop(0.6, old ? '#1c130b' : `rgb(${tint})`); g.addColorStop(1, '#020205'); ctx.fillStyle = g; ctx.fillRect(-400, -200, W + 800, H + 400);
  const wrap = (x, m) => ((x % m) + m) % m;
  for (let i = -1; i < 9; i++) {   // ribs
    const x = i * 300 - wrap(pos, 300), sm = Math.min(220, Math.abs(v) * 0.05);
    ctx.fillStyle = old ? 'rgba(90,64,36,0.35)' : 'rgba(60,70,120,0.3)'; ctx.fillRect(x, 150, 30 + sm, 640);
    ctx.fillStyle = 'rgba(0,0,0,0.4)'; ctx.fillRect(x + 30 + sm, 150, 8, 640);
  }
  ctx.strokeStyle = old ? 'rgba(120,90,50,0.3)' : 'rgba(90,100,150,0.3)'; ctx.lineWidth = 3; [250, 268, 300].forEach(yy => { ctx.beginPath(); ctx.moveTo(-400, yy); ctx.lineTo(W + 400, yy); ctx.stroke(); });
  for (let i = -1; i < 6; i++) {   // lamps
    const x = i * 520 + 200 - wrap(pos, 520), sm = Math.min(480, Math.abs(v) * 0.11);
    const lg = ctx.createLinearGradient(x, 0, x + sm + 4, 0); lg.addColorStop(0, `rgba(${lamp},0.95)`); lg.addColorStop(1, `rgba(${lamp},${sm > 20 ? 0 : 0.95})`);
    ctx.fillStyle = lg; ctx.beginPath(); ctx.roundRect(x, 204, 12 + sm, 8, 4); ctx.fill();
    glowAt(x + 6 + sm * 0.3, 208, 150 + sm * 0.3, lamp, 0.28);
  }
  // track bed
  ctx.fillStyle = '#04040a'; ctx.fillRect(-400, y + 40, W + 800, H);
  ctx.fillStyle = old ? 'rgba(150,120,80,0.5)' : 'rgba(150,165,200,0.5)'; ctx.fillRect(-400, y + 34, W + 800, 4);
  for (let i = -1; i < 40; i++) { const x = i * 56 - wrap(pos, 56); ctx.fillStyle = 'rgba(60,50,45,0.6)'; ctx.fillRect(x, y + 40, 22 + Math.min(34, Math.abs(v) * 0.03), 7); }
}
/** Sparks thrown from the wheels of a braking train. */
function sparks(t, x, y, a) {
  if (a <= 0) return;
  const r = rng(Math.floor(t * 30) + 3);
  ctx.save(); ctx.globalCompositeOperation = 'lighter'; ctx.lineCap = 'round';
  for (let i = 0; i < 26; i++) { const ang = -0.2 - r() * 1.1, len = (20 + r() * 110) * a, sx = x + r() * 16, sy = y - r() * 6; ctx.strokeStyle = `rgba(255,${170 + Math.floor(r() * 80)},90,${a * (0.4 + 0.6 * r())})`; ctx.lineWidth = 1 + r() * 2; ctx.beginPath(); ctx.moveTo(sx, sy); ctx.lineTo(sx - Math.cos(ang) * len, sy + Math.sin(ang) * len * 0.5); ctx.stroke(); }
  glowAt(x, y, 120 * a, '255,190,110', 0.6 * a); ctx.restore();
}
/** A signal on the tunnel wall. */
function signal(x, y, color = '255,50,40', a = 1) {
  ctx.fillStyle = '#0a0a12'; ctx.fillRect(x - 3, y, 6, 150); ctx.beginPath(); ctx.roundRect(x - 16, y - 70, 32, 80, 8); ctx.fill();
  ['40,40,48', '40,40,48', color].forEach((c, i) => { ctx.fillStyle = `rgb(${c})`; ctx.beginPath(); ctx.arc(x, y - 54 + i * 22, 8, 0, Math.PI * 2); ctx.fill(); });
  glowAt(x, y - 10, 320, color, 0.45 * a); glowAt(x, y - 10, 40, color, 0.9 * a);
}

// ---------- a wet street of brownstones ----------
const STOOPS = (() => { const r = rng(61), out = []; let x = -80; while (x < W + 100) { const w = 250 + r() * 70; out.push({ x, w, h: 520 + r() * 110, c: ['#2a1622', '#33201a', '#241a2e', '#3a1c1c', '#1f1b30'][Math.floor(r() * 5)], seed: Math.floor(r() * 1e5), escape: r() < 0.45 }); x += w; } return out; })();
/** The row of brownstones on its own, shifted by `dx` (it repeats every STOOPS_W), drawn only where it falls inside
 *  x0..x1: a film that runs along the street draws it as often as its camera needs. */
const STOOPS_W = STOOPS[STOOPS.length - 1].x + STOOPS[STOOPS.length - 1].w - STOOPS[0].x;
function stoopRow(t, { ground = 850, lit = 1, dx = 0, x0 = -50, x1 = W + 50 } = {}) {
  STOOPS.forEach(b0 => {
    const b = dx ? { ...b0, x: b0.x + dx } : b0, top = ground - b.h;
    if (b.x > x1 || b.x + b.w < x0) return;
    ctx.fillStyle = b.c; ctx.fillRect(b.x, top, b.w, b.h);
    ctx.fillStyle = 'rgba(0,0,0,0.35)'; ctx.fillRect(b.x, top, b.w, 16); ctx.fillRect(b.x + b.w - 5, top, 5, b.h);
    ctx.fillStyle = 'rgba(255,255,255,0.05)'; ctx.fillRect(b.x - 4, top - 8, b.w + 8, 10);
    for (let fl = 0; fl < 3; fl++) for (let c = 0; c < 3; c++) {
      const wx = b.x + 34 + c * (b.w - 68 - 44) / 2, wy = top + 54 + fl * 138, on = hash(b.seed + fl * 7 + c * 3) < 0.55 * lit;
      ctx.fillStyle = '#0a0a16'; ctx.fillRect(wx - 5, wy - 5, 54, 96);
      if (on) { const wg = ctx.createLinearGradient(0, wy, 0, wy + 86); wg.addColorStop(0, `rgba(255,214,140,${0.85 + 0.1 * Math.sin(t * 0.8 + c)})`); wg.addColorStop(1, 'rgba(255,160,80,0.75)'); ctx.fillStyle = wg; ctx.fillRect(wx, wy, 44, 86); if (hash(b.seed + fl + c) < 0.3) { ctx.fillStyle = 'rgba(20,14,30,0.8)'; ctx.beginPath(); ctx.arc(wx + 22, wy + 52, 9, 0, Math.PI * 2); ctx.fill(); ctx.fillRect(wx + 10, wy + 60, 24, 26); } }
      else { ctx.fillStyle = 'rgba(60,70,120,0.35)'; ctx.fillRect(wx, wy, 44, 86); }
      ctx.fillStyle = '#0a0a16'; ctx.fillRect(wx, wy + 41, 44, 3); ctx.fillRect(wx + 20.5, wy, 3, 86);
    }
    if (b.escape) { ctx.strokeStyle = '#07070f'; ctx.lineWidth = 3; for (let fl = 0; fl < 3; fl++) { const y0 = top + 150 + fl * 138; ctx.strokeRect(b.x + 20, y0 - 24, b.w - 40, 24); ctx.beginPath(); ctx.moveTo(b.x + 40, y0); ctx.lineTo(b.x + b.w - 60, y0 + 114); ctx.stroke(); for (let k = 0; k < 9; k++) { ctx.beginPath(); ctx.moveTo(b.x + 24 + k * (b.w - 48) / 8, y0 - 24); ctx.lineTo(b.x + 24 + k * (b.w - 48) / 8, y0); ctx.stroke(); } } }
    // the stoop and the door
    const sx = b.x + b.w * 0.62; ctx.fillStyle = '#0c0a14'; ctx.fillRect(sx - 4, ground - 150, 56, 110); ctx.fillStyle = `rgba(255,200,120,${0.5 * lit})`; ctx.fillRect(sx + 4, ground - 144, 40, 20);
    for (let k = 0; k < 5; k++) { ctx.fillStyle = k % 2 ? '#1a1320' : '#231a2a'; ctx.fillRect(sx - 14 - k * 9, ground - 40 + k * 8, 76 + k * 18, 8); }
  });
}
/** The same row along a street of any length: world coordinates x0..x1, dragged `smear` px by the speed of the camera. */
function stoopsAlong(t, x0, x1, { ground = 850, smear = 0, lit = 0.3 } = {}) {
  const n0 = Math.floor((x0 - STOOPS[0].x) / STOOPS_W) - 1, n1 = Math.floor((x1 - STOOPS[0].x) / STOOPS_W);
  const pass = sm => { for (let n = n0; n <= n1; n++) stoopRow(t, { ground, lit, dx: n * STOOPS_W + sm, x0: x0 - 60, x1: x1 + 60 }); };
  if (smear < 3) return pass(0);
  const a0 = ctx.globalAlpha;
  for (let i = 0; i < 5; i++) { ctx.globalAlpha = a0 / (i + 1); pass(i * smear / 5); }
  ctx.globalAlpha = a0;
}
/** Streaks of light pulled across the frame by speed, a new set every frame: warm for a sunrise, `cool` for a wet night. */
function speedLines(t, a, { y0 = 140, y1 = 1000, n = 30, dir = -1, cool = false } = {}) {
  if (a <= 0) return;
  const r = rng(Math.floor(t * 30) * 7 + 1);
  ctx.save(); ctx.globalCompositeOperation = 'lighter'; ctx.lineCap = 'round';
  for (let i = 0; i < n; i++) {
    const y = lerp(y0, y1, r()), x = r() * (W + 600) - 300, len = 160 + r() * 640, g = 205 + Math.floor(r() * 40), al = a * (0.05 + 0.2 * r());
    ctx.strokeStyle = cool ? `rgba(170,${g},255,${al})` : `rgba(255,${g},170,${al})`; ctx.lineWidth = 1 + r() * 3;
    ctx.beginPath(); ctx.moveTo(x, y); ctx.lineTo(x + dir * len, y); ctx.stroke();
  }
  ctx.restore();
}
function street(t, { ground = 850, lit = 1 } = {}) {
  nightSky('#050716', '#191c44', 0.35);
  drawBlock(BLOCKS.far, t, { base: 600, fill: '#141845', dx: -260, winA: 0.4, lit: 0.3, sx: 10, sy: 13, ww: 3.5, wh: 5 });
  empire(460, 640, 0.62, '#131741', 0.9);
  stoopRow(t, { ground, lit });
  // street lamps
  [330, 1130].forEach(x => { ctx.strokeStyle = '#07070f'; ctx.lineWidth = 7; ctx.beginPath(); ctx.moveTo(x, ground); ctx.lineTo(x, ground - 330); ctx.quadraticCurveTo(x, ground - 380, x + 46, ground - 380); ctx.stroke(); ctx.fillStyle = '#ffe9b8'; ctx.beginPath(); ctx.ellipse(x + 52, ground - 372, 15, 9, 0, 0, Math.PI * 2); ctx.fill(); glowAt(x + 52, ground - 366, 300, '255,205,130', 0.4); ctx.save(); ctx.globalCompositeOperation = 'lighter'; const cg = ctx.createLinearGradient(0, ground - 366, 0, ground); cg.addColorStop(0, 'rgba(255,205,130,0.16)'); cg.addColorStop(1, 'rgba(255,205,130,0)'); poly([[x + 40, ground - 366], [x + 64, ground - 366], [x + 250, ground], [x - 150, ground]], cg); ctx.restore(); });
  // the pavement and the road, wet
  const g = ctx.createLinearGradient(0, ground, 0, H); g.addColorStop(0, '#15142a'); g.addColorStop(0.25, '#0a0a18'); g.addColorStop(1, '#030308'); ctx.fillStyle = g; ctx.fillRect(0, ground, W, H - ground);
  ctx.fillStyle = 'rgba(255,255,255,0.06)'; ctx.fillRect(0, ground + 44, W, 3);
  const r = rng(12);
  for (let i = 0; i < 90; i++) { const x = r() * W, len = 30 + r() * 150, c = r() < 0.2 ? '62,224,143' : r() < 0.3 ? '255,90,70' : '255,205,130', lg = ctx.createLinearGradient(0, ground + 50, 0, ground + 50 + len); lg.addColorStop(0, `rgba(${c},${0.3 * r()})`); lg.addColorStop(1, `rgba(${c},0)`); ctx.fillStyle = lg; ctx.fillRect(x + Math.sin(t * 2 + i) * 3, ground + 50, 3 + r() * 9, len); }
}
/** The way down: the railings, the two green globes, the sign for `line`. Its stairs start at x and go down to the right. */
function subwayEntrance(x, ground, t, line = '6') {
  ctx.fillStyle = '#020207'; poly([[x, ground], [x + 250, ground], [x + 250, ground + 70], [x + 40, ground + 70]], '#020207');
  for (let k = 0; k < 7; k++) { ctx.fillStyle = `rgba(255,214,150,${0.05 + k * 0.03})`; ctx.fillRect(x + 30 + k * 30, ground + 6 + k * 9, 220 - k * 30, 3); }
  glowAt(x + 180, ground + 50, 190, '255,214,150', 0.3);
  ctx.strokeStyle = '#0d3b2a'; ctx.lineWidth = 6; ctx.beginPath(); ctx.moveTo(x - 6, ground); ctx.lineTo(x - 6, ground - 70); ctx.lineTo(x + 260, ground - 70); ctx.lineTo(x + 260, ground); ctx.stroke();
  ctx.lineWidth = 3; for (let k = 1; k < 12; k++) { ctx.beginPath(); ctx.moveTo(x - 6 + k * 22, ground - 70); ctx.lineTo(x - 6 + k * 22, ground); ctx.stroke(); }
  [x - 6, x + 260].forEach((px, i) => { ctx.strokeStyle = '#0d3b2a'; ctx.lineWidth = 7; ctx.beginPath(); ctx.moveTo(px, ground - 70); ctx.lineTo(px, ground - 210); ctx.stroke(); ctx.fillStyle = NY.globe; ctx.beginPath(); ctx.arc(px, ground - 232, 24, 0, Math.PI * 2); ctx.fill(); ctx.fillStyle = 'rgba(255,255,255,0.5)'; ctx.beginPath(); ctx.arc(px - 7, ground - 240, 7, 0, Math.PI * 2); ctx.fill(); glowAt(px, ground - 232, 200, '62,224,143', 0.5 + 0.05 * Math.sin(t * 3 + i)); });
  ctx.fillStyle = '#0a0a12'; ctx.beginPath(); ctx.roundRect(x + 30, ground - 190, 196, 56, 6); ctx.fill();
  text('Subway', x + 52, ground - 151, { size: 30, weight: 800, color: '#fff', display: false });
  bullet(x + 196, ground - 162, 17, line);
}
/** A cab going by, its lights on the wet road. */
function taxi(x, y, s, dir = 1) {
  ctx.save(); ctx.translate(x, y); ctx.scale(s * dir, s);
  const hl = ctx.createLinearGradient(120, 0, 520, 0); hl.addColorStop(0, 'rgba(255,240,200,0.2)'); hl.addColorStop(1, 'rgba(255,240,200,0)'); ctx.save(); ctx.globalCompositeOperation = 'lighter'; poly([[118, -42], [520, -110], [520, 20], [118, -30]], hl); ctx.restore();
  ctx.fillStyle = NY.taxi; ctx.beginPath(); ctx.roundRect(-130, -62, 260, 46, 12); ctx.fill(); poly([[-80, -62], [-56, -104], [56, -104], [86, -62]], NY.taxi);
  ctx.fillStyle = '#10111e'; poly([[-66, -64], [-48, -96], [-4, -96], [-4, -64]], '#10111e'); poly([[4, -64], [4, -96], [50, -96], [70, -64]], '#10111e');
  ctx.fillStyle = '#fff3c4'; ctx.fillRect(-16, -116, 32, 12); ctx.fillStyle = '#10111e'; for (let i = 0; i < 12; i++) if (i % 2) ctx.fillRect(-120 + i * 20, -44, 20, 7);
  [-82, 84].forEach(wx => { ctx.fillStyle = '#07070c'; ctx.beginPath(); ctx.arc(wx, -14, 21, 0, Math.PI * 2); ctx.fill(); ctx.fillStyle = '#3a3c48'; ctx.beginPath(); ctx.arc(wx, -14, 9, 0, Math.PI * 2); ctx.fill(); });
  ctx.fillStyle = '#fff6d6'; ctx.fillRect(122, -48, 9, 12); ctx.fillStyle = '#ff3b30'; ctx.fillRect(-132, -50, 6, 14);
  ctx.restore();
  glowAt(x + dir * 128 * s, y - 42 * s, 90 * s, '255,240,200', 0.7); glowAt(x - dir * 130 * s, y - 42 * s, 70 * s, '255,60,48', 0.5);
}

// ---------- an island platform, looking down it ----------
const PV = { x: 960, y: 470 };
const px3 = (X, Y, z) => [PV.x + X / z, PV.y + Y / z];
/** Trains on both sides, columns and lights running away to a point. `left` and `right` are {lit, door, tint, body};
 *  `between` draws whoever is on the platform, behind the nearest columns. */
function islandPlatform(t, { left = {}, right = {}, between = null } = {}) {
  ctx.fillStyle = '#05060e'; ctx.fillRect(0, 0, W, H);
  const quad = (a, b, c, d, fill) => poly([a, b, c, d], fill);
  // floor and ceiling
  const fg = ctx.createLinearGradient(0, PV.y, 0, H); fg.addColorStop(0, '#0a0c1c'); fg.addColorStop(1, '#262a44'); quad(px3(-640, 430, 0.5), px3(640, 430, 0.5), px3(640, 430, 12), px3(-640, 430, 12), fg);
  quad(px3(-640, -340, 0.5), px3(640, -340, 0.5), px3(640, -340, 12), px3(-640, -340, 12), '#070812');
  [-1, 1].forEach(s => quad(px3(s * 640, 430, 0.5), px3(s * 560, 430, 0.5), px3(s * 560, 430, 12), px3(s * 640, 430, 12), 'rgba(255,198,46,0.75)'));
  // the two trains: walls of light running to the vanishing point
  [[-1, left], [1, right]].forEach(([s, o]) => {
    const { lit = 1, door = 0, tint = '255,226,170', body = '#7f8a9a' } = o, X = s * 660;
    quad(px3(X, -300, 0.5), px3(X, 430, 0.5), px3(X, 430, 12), px3(X, -300, 12), body);
    const sh = ctx.createLinearGradient(PV.x + s * 880, 0, PV.x, 0); sh.addColorStop(0, 'rgba(0,0,0,0)'); sh.addColorStop(1, 'rgba(0,0,0,0.75)'); quad(px3(X, -300, 0.5), px3(X, 430, 0.5), px3(X, 430, 12), px3(X, -300, 12), sh);
    for (let k = 0; k < 26; k++) {
      const z0 = 0.8 + k * 0.42, isDoor = k % 4 === 1, z1 = z0 + (isDoor ? 0.26 : 0.32);
      if (isDoor) {
        if (door > 0) { quad(px3(X, -210, z0), px3(X, 430, z0), px3(X, 430, z1), px3(X, -210, z1), `rgba(${tint},${0.95 * lit * door})`);
          ctx.save(); ctx.globalCompositeOperation = 'lighter'; const [ax, ay] = px3(X, 430, z0), [bx, by] = px3(X, 430, z1), [cx2, cy2] = px3(X - s * 520, 430, z1 + 0.1), [dx2, dy2] = px3(X - s * 520, 430, z0 - 0.1); const lg = ctx.createLinearGradient(ax, 0, cx2, 0); lg.addColorStop(0, `rgba(${tint},${0.5 * lit * door})`); lg.addColorStop(1, `rgba(${tint},0)`); poly([[ax, ay], [bx, by], [cx2, cy2], [dx2, dy2]], lg); ctx.restore(); }
        else { quad(px3(X, -210, z0), px3(X, 430, z0), px3(X, 430, z1), px3(X, -210, z1), 'rgba(20,24,36,0.55)'); quad(px3(X, -150, z0 + 0.03), px3(X, 60, z0 + 0.03), px3(X, 60, z1 - 0.03), px3(X, -150, z1 - 0.03), `rgba(${tint},${0.75 * lit})`); }
      } else quad(px3(X, -150, z0), px3(X, 60, z0), px3(X, 60, z1), px3(X, -150, z1), `rgba(${tint},${(0.85 - 0.25 * hash(k + s)) * lit})`);
    }
  });
  // columns and the lights over the platform
  for (let k = 14; k >= 0; k--) {
    const z = 1.15 + k * 0.75;
    if (k === 0 && between) between();   // whoever is crossing passes behind the nearest columns
    [-1, 1].forEach(s => { const [x0, y0] = px3(s * 400, -340, z), [x1, y1] = px3(s * 400, 430, z), w = 34 / z; ctx.fillStyle = '#0e2a22'; ctx.fillRect(x0 - w / 2, y0, w, y1 - y0); ctx.fillStyle = 'rgba(255,255,255,0.08)'; ctx.fillRect(x0 - w / 2, y0, w * 0.25, y1 - y0); });
    const [lx, ly] = px3(0, -330, z + 0.3), lw = 260 / (z + 0.3); ctx.fillStyle = 'rgba(225,238,255,0.95)'; ctx.fillRect(lx - lw / 2, ly, lw, 7 / (z + 0.3)); glowAt(lx, ly, 320 / (z + 0.3), '200,220,255', 0.3);
    const [bx0, by0] = px3(-640, -340, z), [bx1] = px3(640, -340, z); ctx.fillStyle = '#0a0b16'; ctx.fillRect(bx0, by0, bx1 - bx0, 16 / z);
  }
}

// ---------- a train braking, held, and the station it stops in ----------
const stride = (x, h, s = 1) => (x / (0.84 * h * s)) * Math.PI * 2;   // the walk keeps step with the ground covered
/** Car lights that have lost their nerve. */
const flicker = (t, seed = 2) => (noise1(t * 11, seed) > -0.1 ? 1 : 0.35) * (0.86 + 0.14 * noise1(t * 31, seed + 1));
/** A train that runs at `v0` px/s from t0, brakes from b0 and stands still at b1: where it is, its speed, how hard it brakes. */
function ride(t, t0, b0, b1, v0) {
  if (t < b0) return { pos: v0 * (t - t0), v: v0, brake: 0 };
  const T = b1 - b0, d = Math.min(t, b1) - b0;
  return { pos: v0 * (b0 - t0) + v0 * (d - d * d / (2 * T)), v: v0 * (1 - d / T), brake: Math.sin(Math.PI * d / T) };
}
/** The lurch of the frame as it stops. */
const jolt = (t, at) => (t > at ? 18 * Math.exp(-(t - at) * 5) * Math.cos((t - at) * 17) : 0);
/** Three cars filling the frame, sparks at the wheels while they brake, the lights dimmed to `o.dim` once stopped. */
function train(t, r, v0, y, o, stopAt) {
  const lit = stopAt != null && t > stopAt ? o.dim * flicker(t) : 1;
  [-760, 250, 1260].forEach((x, i) => subwayCar(x, y, 1000, { ...o, lit, seed: i + 1 }));
  if (r.brake > 0.02) [-620, -520, 0, 100, 390, 490, 1010, 1110, 1400, 1500].forEach(x => sparks(t + x, x + 2, y + 86, r.brake * (0.5 + 0.5 * hash(x + Math.floor(t * 20)))));
}
/** A local station going by behind the train: tile, a band of mosaic, the name, columns, people waiting. `blur` (px) smears it. */
function stationWall(x0, name, blur = 0, len = 2700, y = 770) {
  const n = blur > 10 ? 14 : 1;
  for (let i = 0; i < n; i++) {
    ctx.save(); ctx.globalAlpha *= 1 / (i + 1); ctx.translate(i * blur / n, 0);
    const g = ctx.createLinearGradient(0, 150, 0, y + 20); g.addColorStop(0, '#9fa598'); g.addColorStop(0.25, '#e3e6d8'); g.addColorStop(1, '#8b9186'); ctx.fillStyle = g; ctx.fillRect(x0, 150, len, y - 130);
    ctx.fillStyle = '#1f5e4c'; ctx.fillRect(x0, 236, len, 30); ctx.fillStyle = '#d7b45a'; ctx.fillRect(x0, 232, len, 4); ctx.fillRect(x0, 266, len, 4);
    ctx.fillStyle = '#4a4e52'; ctx.fillRect(x0, y - 24, len, 64); ctx.fillStyle = NY.taxi; ctx.fillRect(x0, y - 24, len, 7);
    for (let x = x0 + 112; x < x0 + len - 300; x += 660) {
      ctx.fillStyle = '#10244a'; ctx.beginPath(); ctx.roundRect(x, 300, 256, 92, 6); ctx.fill(); ctx.strokeStyle = '#d7b45a'; ctx.lineWidth = 4; ctx.stroke();
      text(name, x + 128, 348, { size: 44, weight: 700, color: '#fff', align: 'center', base: 'middle', display: false });
      if (blur < 60) [90, 400, 470].forEach((dx, j) => figure(x + dx, y - 22, 170 + j * 8, { coat: '#22263a', legs: '#151726', skin: '#22263a', dir: j % 2 ? 1 : -1, hat: j === 1 ? '#22263a' : false }));
    }
    for (let x = x0 + 60; x < x0 + len; x += 330) { ctx.fillStyle = '#143a2c'; ctx.fillRect(x, 150, 30, y - 130); ctx.fillStyle = 'rgba(255,255,255,0.1)'; ctx.fillRect(x, 150, 7, y - 130); }
    ctx.restore();
  }
}
/** A sign hung over the platform: a line's bullet and a word. */
function hangSign(x, y, b, s, color, a = 1) {
  ctx.save(); ctx.globalAlpha *= a;
  ctx.fillStyle = '#0a0b12'; ctx.fillRect(x - 3, y - 80, 6, 80); ctx.beginPath(); ctx.roundRect(x - 150, y, 300, 76, 8); ctx.fill();
  bullet(x - 106, y + 38, 25, b); text(s, x - 66, y + 39, { size: 28, weight: 700, color, base: 'middle', display: false });
  ctx.restore();
}
