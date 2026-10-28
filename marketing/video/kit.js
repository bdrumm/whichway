// Shared drawing kit for the films: canvas, palette, easing, text, the phone, line bullets, the app icon.
// A film page loads this, then defines DURATION and render(t).
const W = 1920, H = 1080;
const cv = document.getElementById('c');
const ctx = cv.getContext('2d');

const C = {
  bg0: '#05070d', bg1: '#0a1430', ink: '#f4f6fb', dim: 'rgba(244,246,251,0.62)', faint: 'rgba(244,246,251,0.28)',
  blue: '#2e7cff', sky: '#5b9bff', ice: '#9cc4ff', card: 'rgba(20,30,58,0.86)', cardLine: 'rgba(156,196,255,0.18)',
  late: '#ff7a1a', red: '#ff4a3d', ok: '#3ddc97',
};
// MTA line colours.
const L = {
  A: '#0039a6', C: '#0039a6', E: '#0039a6', F: '#ff6319', D: '#ff6319', M: '#ff6319', N: '#fccc0a', Q: '#fccc0a',
  R: '#fccc0a', 1: '#ee352e', 2: '#ee352e', 3: '#ee352e', 4: '#00933c', 5: '#00933c', 6: '#00933c', 7: '#b933ad',
  G: '#6cbe45', L: '#a7a9ac', J: '#996633', B: '#ff6319',
};

// ---------- helpers ----------
const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
const lerp = (a, b, k) => a + (b - a) * k;
const seg = (t, a, b) => clamp((t - a) / (b - a));
const easeOut = k => 1 - Math.pow(1 - k, 3);
const easeIn = k => k * k * k;
const easeInOut = k => (k < 0.5 ? 4 * k * k * k : 1 - Math.pow(-2 * k + 2, 3) / 2);
const expoOut = k => (k >= 1 ? 1 : 1 - Math.pow(2, -10 * k));
/** 0 → 1 → 0 over [a, b], with fades of length f at both ends. */
const life = (t, a, b, f = 0.5) => Math.min(easeOut(seg(t, a, a + f)), 1 - easeIn(seg(t, b - f, b)));
function rng(seed) { let s = seed >>> 0; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296); }
function noise1(x, seed = 0) {
  const i = Math.floor(x), f = x - i, h = n => { const s = Math.sin((n + seed * 131.7) * 127.1) * 43758.5453; return s - Math.floor(s); };
  const u = f * f * (3 - 2 * f); return lerp(h(i), h(i + 1), u) * 2 - 1;
}

function font(size, weight = 600, display = true) { return `${weight} ${size}px ${display ? '"Inter Display", Inter' : 'Inter'}, sans-serif`; }
function text(s, x, y, { size = 40, weight = 600, color = C.ink, alpha = 1, align = 'left', base = 'alphabetic', spacing = 0, display = true, mono = false } = {}) {
  if (alpha <= 0) return;
  ctx.save();
  ctx.globalAlpha *= alpha;
  ctx.font = mono ? `${weight} ${size}px "DejaVu Sans Mono", monospace` : font(size, weight, display);
  ctx.letterSpacing = `${spacing}px`;
  ctx.fillStyle = color; ctx.textAlign = align; ctx.textBaseline = base;
  ctx.fillText(s, x, y);
  ctx.restore();
}
function measure(s, size, weight = 600, spacing = 0) {
  ctx.save(); ctx.font = font(size, weight); ctx.letterSpacing = `${spacing}px`; const w = ctx.measureText(s).width; ctx.restore(); return w;
}
/** A line of text that rises into place and fades in, starting at `at`; leaves at `out`. */
function riseText(t, s, x, y, at, out, opts = {}) {
  const k = easeOut(seg(t, at, at + 0.9));
  const o = out == null ? 1 : 1 - easeIn(seg(t, out, out + 0.6));
  const dy = (1 - k) * (opts.rise ?? 28) - (out == null ? 0 : easeIn(seg(t, out, out + 0.6)) * 14);
  ctx.save();
  if (opts.blur) ctx.filter = `blur(${(1 - k) * 10}px)`;
  text(s, x, y + dy, { ...opts, alpha: (opts.alpha ?? 1) * k * o });
  ctx.restore();
}
function rrect(x, y, w, h, r) { ctx.beginPath(); ctx.roundRect(x, y, w, h, r); }
function bullet(x, y, r, label, alpha = 1) {
  if (alpha <= 0) return;
  ctx.save(); ctx.globalAlpha *= alpha;
  ctx.fillStyle = L[label] || C.blue; ctx.beginPath(); ctx.arc(x, y, r, 0, Math.PI * 2); ctx.fill();
  const dark = 'NQR'.includes(label);
  text(label, x, y + r * 0.04, { size: r * 1.25, weight: 700, color: dark ? '#111' : '#fff', align: 'center', base: 'middle', display: false });
  ctx.restore();
}
function glowStroke(path, color, width, glow = 18, alpha = 1) {
  ctx.save(); ctx.globalAlpha *= alpha; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
  ctx.strokeStyle = color; ctx.shadowColor = color; ctx.shadowBlur = glow; ctx.lineWidth = width; ctx.stroke(path);
  ctx.shadowBlur = 0; ctx.stroke(path); ctx.restore();
}
function background(t, tint = 0) {
  const g = ctx.createRadialGradient(W * 0.5, H * 0.35, 50, W * 0.5, H * 0.5, W * 0.75);
  g.addColorStop(0, `rgb(${lerp(13, 20, tint)},${lerp(24, 40, tint)},${lerp(56, 92, tint)})`);
  g.addColorStop(1, C.bg0);
  ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
}
/** Slow drifting dust, for depth. */
function dust(t, alpha = 0.5, n = 70) {
  const r = rng(7);
  ctx.save();
  for (let i = 0; i < n; i++) {
    const x0 = r() * W, y0 = r() * H, sp = 6 + r() * 22, s = 0.6 + r() * 1.8;
    const x = (x0 + t * sp) % (W + 40) - 20, y = y0 + Math.sin(t * 0.3 + i) * 8;
    ctx.globalAlpha = alpha * (0.15 + 0.5 * r());
    ctx.fillStyle = C.ice; ctx.beginPath(); ctx.arc(x, y, s, 0, Math.PI * 2); ctx.fill();
  }
  ctx.restore();
}
function vignette(a = 0.65) {
  const g = ctx.createRadialGradient(W / 2, H / 2, H * 0.35, W / 2, H / 2, H * 1.05);
  g.addColorStop(0, 'rgba(0,0,0,0)'); g.addColorStop(1, `rgba(0,0,0,${a})`);
  ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
}

// ---------- the phone ----------
const PW = 420, PH = 860;
function phone(cx, cy, scale, alpha, drawScreen) {
  if (alpha <= 0) return;
  ctx.save();
  ctx.globalAlpha *= alpha;
  ctx.translate(cx, cy); ctx.scale(scale, scale); ctx.translate(-PW / 2, -PH / 2);
  ctx.shadowColor = 'rgba(46,124,255,0.35)'; ctx.shadowBlur = 90;
  rrect(-14, -14, PW + 28, PH + 28, 78); ctx.fillStyle = '#1b1f2a'; ctx.fill();
  ctx.shadowBlur = 0;
  rrect(-14, -14, PW + 28, PH + 28, 78); ctx.strokeStyle = 'rgba(255,255,255,0.18)'; ctx.lineWidth = 2; ctx.stroke();
  rrect(0, 0, PW, PH, 64); ctx.save(); ctx.clip();
  const g = ctx.createLinearGradient(0, 0, 0, PH); g.addColorStop(0, '#0d1630'); g.addColorStop(1, '#060a16');
  ctx.fillStyle = g; ctx.fillRect(0, 0, PW, PH);
  drawScreen();
  ctx.restore();
  rrect(PW / 2 - 62, 16, 124, 36, 18); ctx.fillStyle = '#000'; ctx.fill();
  text('9:41', 50, 44, { size: 20, weight: 600, display: false });
  ctx.restore();
}
function screenCard(x, y, w, h, alpha = 1) {
  ctx.save(); ctx.globalAlpha *= alpha;
  rrect(x, y, w, h, 26); ctx.fillStyle = 'rgba(255,255,255,0.06)'; ctx.fill();
  ctx.strokeStyle = 'rgba(255,255,255,0.09)'; ctx.lineWidth = 1.5; ctx.stroke(); ctx.restore();
}
function chip(x, y, label, color, alpha = 1, size = 20) {
  if (alpha <= 0) return;
  const w = measure(label, size, 600) + 34;
  ctx.save(); ctx.globalAlpha *= alpha;
  rrect(x, y, w, size + 18, (size + 18) / 2); ctx.fillStyle = color + '33'; ctx.fill();
  ctx.strokeStyle = color + '99'; ctx.lineWidth = 1.5; ctx.stroke();
  text(label, x + 17, y + (size + 18) / 2 + 1, { size, weight: 600, color, base: 'middle' });
  ctx.restore();
  return w;
}

// ---------- the icon ----------
/** The app icon's switch: a faded branch, the bright branch to a station dot, the stem to a hollow ring.
 *  p0..p3 reveal the parts (0..1). Coordinates in a 1024 box. */
function iconMark(cx, cy, size, { stem = 1, right = 1, left = 1, dot = 1, color = '#fff', glow = 0 } = {}) {
  const s = size / 1024;
  ctx.save(); ctx.translate(cx - size / 2, cy - size / 2); ctx.scale(s, s);
  ctx.lineCap = 'round'; ctx.lineJoin = 'round'; ctx.lineWidth = 92;
  const fork = [512, 560];
  const leftPath = new Path2D(); leftPath.moveTo(fork[0], fork[1]); leftPath.bezierCurveTo(470, 520, 330, 450, 330, 330); leftPath.lineTo(330, 300);
  const rightPath = new Path2D(); rightPath.moveTo(fork[0], fork[1]); rightPath.bezierCurveTo(560, 515, 700, 440, 712, 300);
  const stemPath = new Path2D(); stemPath.moveTo(512, 560); stemPath.lineTo(512, 680);
  const dash = (len, k) => { ctx.setLineDash([len * k, len * 2]); };
  if (glow) { ctx.shadowColor = C.sky; ctx.shadowBlur = glow / s; }
  if (left > 0) { ctx.strokeStyle = 'rgba(255,255,255,0.35)'; dash(420, left); ctx.stroke(leftPath); }
  if (stem > 0) { ctx.strokeStyle = color; dash(130, stem); ctx.stroke(stemPath); }
  if (right > 0) { ctx.strokeStyle = color; dash(400, right); ctx.stroke(rightPath); }
  ctx.setLineDash([]);
  if (stem > 0) {
    ctx.beginPath(); ctx.arc(512, 770, 104 * easeOut(clamp(stem * 1.4 - 0.2)), 0, Math.PI * 2); ctx.fillStyle = color; ctx.fill();
    ctx.beginPath(); ctx.arc(512, 770, 46 * easeOut(clamp(stem * 1.4 - 0.2)), 0, Math.PI * 2); ctx.globalCompositeOperation = 'destination-out'; ctx.fill();
    ctx.globalCompositeOperation = 'source-over';
  }
  if (dot > 0) { ctx.beginPath(); ctx.arc(726, 262, 112 * expoOut(dot), 0, Math.PI * 2); ctx.fillStyle = color; ctx.fill(); }
  ctx.restore();
}
function iconTile(cx, cy, size, k, markK) {
  ctx.save();
  ctx.translate(cx, cy); ctx.scale(k, k); ctx.translate(-cx, -cy);
  const x = cx - size / 2, y = cy - size / 2;
  ctx.shadowColor = 'rgba(46,124,255,0.6)'; ctx.shadowBlur = 120;
  rrect(x, y, size, size, size * 0.225);
  const g = ctx.createLinearGradient(x, y, x + size, y + size); g.addColorStop(0, '#4a8dff'); g.addColorStop(0.55, '#0a49c9'); g.addColorStop(1, '#0035a8');
  ctx.fillStyle = g; ctx.fill(); ctx.shadowBlur = 0;
  rrect(x, y, size, size, size * 0.225); ctx.save(); ctx.clip();
  // the left-branch ring cut-out reads as hollow on the tile, so redraw it in the tile's colour
  iconMark(cx, cy, size, markK);
  ctx.restore();
  ctx.restore();
}


/** Hands a film to the renderer (render.mjs steps window.render) and, opened plainly, plays it in a loop. */
function boot(duration, render) {
  window.render = render;
  window.DURATION = duration;
  window.ready = document.fonts.load('700 40px "Inter Display"').then(() => document.fonts.load('500 40px Inter'));
  if (!location.search.includes('static')) {
    window.ready.then(() => {
      const t0 = performance.now();
      const loop = () => { render(((performance.now() - t0) / 1000) % duration); requestAnimationFrame(loop); };
      loop();
    });
  }
}
/** The closing card shared by the films: the icon draws itself, then the name and a line. */
function endCard(t, at, line, sub) {
  if (t < at - 0.2) return;
  const k = easeOut(seg(t, at, at + 1.4));
  const tileK = lerp(0.6, 1, expoOut(seg(t, at, at + 1.8)));
  const markK = { stem: seg(t, at + 0.4, at + 1.4), right: easeInOut(seg(t, at + 1, at + 2.2)), left: easeInOut(seg(t, at + 1.2, at + 2.4)), dot: seg(t, at + 2, at + 2.7) };
  ctx.save(); ctx.globalAlpha = k;
  const lift = easeInOut(seg(t, at + 2.6, at + 3.8));
  iconTile(W / 2, lerp(540, 430, lift), 300, tileK, markK);
  riseText(t, 'WhichWay', W / 2, 700, at + 2.8, null, { size: 104, weight: 800, align: 'center', spacing: -2 });
  if (line) riseText(t, line, W / 2, 770, at + 3.5, null, { size: 40, weight: 500, align: 'center', color: C.ice, display: false });
  if (sub) riseText(t, sub, W / 2, 870, at + 4.3, null, { size: 26, weight: 600, align: 'center', color: C.faint, spacing: 3, display: false });
  ctx.restore();
}
/** Fade up from black at the start and down to black at the end. */
function blackFades(t, duration) {
  const black = Math.max(1 - seg(t, 0, 0.8), seg(t, duration - 0.8, duration));
  if (black > 0) { ctx.fillStyle = `rgba(0,0,0,${black})`; ctx.fillRect(0, 0, W, H); }
}
