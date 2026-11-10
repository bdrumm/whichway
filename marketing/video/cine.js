// What the cinematic cuts share: film grain, darkness for the words to sit on, lines that rise or land hard, numbers
// that roll, the cinema's bars. Needs kit.js.
const GRAIN = (() => {
  const g = document.createElement('canvas'); g.width = g.height = 512;
  const x = g.getContext('2d'), d = x.createImageData(512, 512), r = rng(5);
  for (let i = 0; i < d.data.length; i += 4) { const v = 128 + (r() - 0.5) * 255; d.data[i] = d.data[i + 1] = d.data[i + 2] = v; d.data[i + 3] = 255; }
  x.putImageData(d, 0, 0); return g;
})();
/** Film grain over the frame, a new pattern every frame. */
function grain(t, a) {
  const r = rng(Math.round(t * 30) + 11);
  ctx.save(); ctx.globalCompositeOperation = 'overlay'; ctx.globalAlpha = a;
  const ox = Math.floor(r() * 512), oy = Math.floor(r() * 512);
  for (let x = -ox; x < W; x += 512) for (let y = -oy; y < H; y += 512) ctx.drawImage(GRAIN, x, y);
  ctx.restore();
}
/** Darkness for the words to sit on: from the left, or rising from the bottom. */
function scrim(side, a = 0.8) {
  const g = side === 'left' ? ctx.createLinearGradient(0, 0, 1250, 0) : ctx.createLinearGradient(0, H, 0, H - 520);
  g.addColorStop(0, `rgba(3,5,10,${a})`); g.addColorStop(0.55, `rgba(3,5,10,${a * 0.6})`); g.addColorStop(1, 'rgba(3,5,10,0)');
  ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
}

function shadowed(fn) { ctx.save(); ctx.shadowColor = 'rgba(0,0,0,0.85)'; ctx.shadowBlur = 26; ctx.shadowOffsetY = 2; fn(); ctx.restore(); }
const say = (t, s, x, y, at, out, o) => shadowed(() => riseText(t, s, x, y, at, out, o));
/** A line that lands hard: big, then exactly in place. */
function slam(t, s, x, y, at, out, o = {}) {
  if (t < at) return;
  const k = expoOut(seg(t, at, at + 0.5)), a = seg(t, at, at + 0.1) * (out == null ? 1 : 1 - easeIn(seg(t, out, out + 0.4)));
  if (a <= 0) return;
  const z = lerp(1.5, 1, k), cx = o.align === 'center' ? x : x + measure(s, o.size, o.weight ?? 800) / 2;
  shadowed(() => {
    ctx.translate(cx, y - o.size * 0.35); ctx.scale(z, z); ctx.translate(-cx, -(y - o.size * 0.35));
    ctx.filter = `blur(${(1 - k) * 8}px)`;
    text(s, x, y, { weight: 800, ...o, alpha: a });
  });
}
/** A number rolling from one value to another. */
const roll = (t, at, dur, from, to) => Math.round(lerp(from, to, easeInOut(seg(t, at, at + dur))));
/** The cinema's bars. */
function bars(h = 70) { ctx.fillStyle = '#000'; ctx.fillRect(0, 0, W, h); ctx.fillRect(0, H - h, W, h); }
