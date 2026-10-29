// The prediction engine, drawn: what the app computes rather than the screens that show it. Stringlines with a hold
// and the trains it holds back, the remaining-hold curve, the arrival window tightening, the arrival odds of two
// routes against a deadline, express against local, and the living network behind the logo.
// Every graphic takes a box {x, y, w, h} and the film's time t; `at` is when it starts drawing itself.

const ENG = { grid: 'rgba(156,196,255,0.10)', axis: 'rgba(156,196,255,0.35)', label: 'rgba(244,246,251,0.55)' };
const mins = (h, m) => h * 60 + m;
const clockTxt = m => `${Math.floor(m / 60) % 12 || 12}:${String(Math.round(m % 60)).padStart(2, '0')}`;
const gauss = (x, mu, sd) => Math.exp(-0.5 * ((x - mu) / sd) ** 2);

function engineFrame(box, a, title) {
  ctx.save(); ctx.globalAlpha *= a;
  if (title) text(title, box.x, box.y - 22, { size: 18, weight: 700, color: ENG.label, spacing: 3, display: false });
  ctx.restore();
}

/** Stringlines (time across, stations down) for one line. Train `mine` is held at stop `heldAt` for `hold` (in chart
 *  time, 0..1); the trains behind it cannot pass and bunch up. Left of the moving "now" line is what the feed saw,
 *  right of it is the engine's projection with its widening window. */
function engineMarey(t, box, o) {
  const { stops, color, at, mine = 3, heldAt = 2, hold = 0.2, now0 = 0.3, now1 = 0.55, nowAt = [at + 1, at + 6], mineColor = '#fff', heldColor = HELD_C, heldLabel = 'HELD' } = o;
  const a = easeOut(seg(t, at, at + 0.8));
  if (a <= 0) return;
  const run = 0.075, dwell = 0.012, headway = 0.03, n = 8;
  // build the trains: arrival/departure per stop, held train dwells long, followers wait behind it
  const trains = [];
  for (let k = 0; k < n; k++) {
    let x = -0.45 + k * 0.11; const pts = [];
    for (let s = 0; s < stops.length; s++) {
      let arr = x;
      if (k > 0) arr = Math.max(arr, trains[k - 1][s].dep + headway);
      let dep = arr + dwell + (k === mine && s === heldAt ? hold : 0);
      pts.push({ arr, dep });
      x = dep + run;
    }
    trains.push(pts);
  }
  const X = v => box.x + 130 + v * (box.w - 130), Y = s => box.y + (s / (stops.length - 1)) * box.h;
  const now = lerp(now0, now1, easeInOut(seg(t, nowAt[0], nowAt[1])));
  ctx.save(); ctx.globalAlpha *= a;
  stops.forEach((s, i) => {
    ctx.fillStyle = ENG.grid; ctx.fillRect(X(0), Y(i), box.w - 130, 1.5);
    text(s, box.x + 110, Y(i) + 6, { size: 18, weight: 500, color: ENG.label, align: 'right', display: false });
  });
  ctx.save(); ctx.beginPath(); ctx.rect(X(0), box.y - 30, box.w - 130, box.h + 60); ctx.clip();
  trains.forEach((pts, k) => {
    const isMine = k === mine, behind = k > mine && k <= mine + 2;
    const seen = new Path2D(), proj = new Path2D(); let ps = false, pp = false;
    const pts2 = []; pts.forEach((p, s) => { pts2.push([p.arr, s]); pts2.push([p.dep, s]); });
    for (let i = 0; i < pts2.length; i++) {
      const [x, s] = pts2[i];
      if (x <= now) { ps ? seen.lineTo(X(x), Y(s)) : seen.moveTo(X(x), Y(s)); ps = true; }
      else {
        if (!pp) {
          // join the projection to where the train is now
          const [x0, s0] = pts2[Math.max(0, i - 1)], f = clamp((now - x0) / ((x - x0) || 1));
          const sy = lerp(s0, s, f);
          if (ps) seen.lineTo(X(now), Y(sy));
          proj.moveTo(X(now), Y(sy)); pp = true;
        }
        proj.lineTo(X(x), Y(s));
      }
    }
    const col = isMine ? mineColor : behind ? heldColor : color;
    glowStroke(seen, col, isMine ? 4.5 : 3, isMine ? 18 : 8, isMine ? 1 : 0.75);
    ctx.save(); ctx.setLineDash([3, 9]); glowStroke(proj, col, isMine ? 4 : 2.5, 8, isMine ? 0.95 : 0.5); ctx.restore();
  });
  // the window around your train's projection, widening with the horizon
  const mp = trains[mine];
  const band = new Path2D(); const up = [], dn = [];
  mp.forEach((p, s) => { if (p.arr > now) { const w = (p.arr - now) * 0.25; up.push([X(p.arr - w), Y(s)]); dn.push([X(p.arr + w), Y(s)]); } });
  if (up.length) {
    band.moveTo(X(now), Y(mp.findIndex(p => p.arr > now) - 0.5 < 0 ? 0 : mp.findIndex(p => p.arr > now) - 0.5));
    up.forEach(([x, y]) => band.lineTo(x, y)); dn.reverse().forEach(([x, y]) => band.lineTo(x, y)); band.closePath();
    ctx.fillStyle = 'rgba(255,255,255,0.07)'; ctx.fill(band);
  }
  ctx.restore();
  // now
  ctx.fillStyle = 'rgba(255,255,255,0.55)'; ctx.fillRect(X(now) - 1, box.y - 30, 2, box.h + 60);
  text('now', X(now), box.y + box.h + 52, { size: 16, weight: 700, color: 'rgba(255,255,255,0.7)', align: 'center', spacing: 2, display: false });
  // the hold, marked
  const hp = mp[heldAt];
  if (now > hp.arr + 0.02) {
    const k = seg(now, hp.arr + 0.02, hp.arr + 0.08);
    ctx.save(); ctx.globalAlpha *= k;
    ctx.fillStyle = 'rgba(255,204,51,0.14)'; ctx.fillRect(X(hp.arr), Y(heldAt) - 16, X(Math.min(now, hp.dep)) - X(hp.arr), 32);
    text(heldLabel, X(hp.arr) + 8, Y(heldAt) - 24, { size: 15, weight: 800, color: heldColor, spacing: 3, display: false });
    ctx.restore();
  }
  ctx.restore();
  return { now };
}
const HELD_C = '#ffcc33';

/** How much longer a hold here lasts, given how long the train has already been held: a curve over minutes, the
 *  middle and the 90th percentile marked, the time held so far counting up. */
function holdCurve(t, box, o) {
  const { at, mu = 12, p90 = 20, heldFor = [1.5, 2.3], color = HELD_C } = o;
  const a = easeOut(seg(t, at, at + 0.8));
  if (a <= 0) return;
  const maxM = 30, X = m => box.x + (m / maxM) * box.w, base = box.y + box.h;
  const draw = easeInOut(seg(t, at + 0.3, at + 2.2));
  const dens = m => { if (m <= 0) return 0; const l = Math.log(m), s = 0.42; return Math.exp(-((l - Math.log(mu)) ** 2) / (2 * s * s)) / m; };
  let peak = 0; for (let m = 0.2; m < maxM; m += 0.2) peak = Math.max(peak, dens(m));
  ctx.save(); ctx.globalAlpha *= a;
  ctx.fillStyle = ENG.axis; ctx.fillRect(box.x, base, box.w, 2);
  [0, 5, 10, 15, 20, 25, 30].forEach(m => text(`${m}`, X(m), base + 30, { size: 17, weight: 500, color: ENG.label, align: 'center', display: false }));
  text('minutes more', box.x + box.w, base + 62, { size: 16, weight: 600, color: ENG.label, align: 'right', spacing: 2, display: false });
  const p = new Path2D(); p.moveTo(X(0), base);
  for (let m = 0; m <= maxM * draw; m += 0.15) p.lineTo(X(m), base - dens(m) / peak * box.h);
  const area = new Path2D(p); area.lineTo(X(maxM * draw), base); area.closePath();
  const g = ctx.createLinearGradient(0, box.y, 0, base); g.addColorStop(0, 'rgba(255,204,51,0.35)'); g.addColorStop(1, 'rgba(255,204,51,0.02)');
  ctx.fillStyle = g; ctx.fill(area);
  glowStroke(p, color, 4, 16, 1);
  const mark = (m, label, sub, k) => {
    if (k <= 0) return;
    ctx.save(); ctx.globalAlpha *= k;
    const y = base - dens(m) / peak * box.h;
    ctx.setLineDash([4, 6]); ctx.strokeStyle = 'rgba(255,255,255,0.6)'; ctx.lineWidth = 2;
    ctx.beginPath(); ctx.moveTo(X(m), base); ctx.lineTo(X(m), y - 40); ctx.stroke(); ctx.setLineDash([]);
    text(label, X(m) + 10, y - 50, { size: 26, weight: 800 });
    text(sub, X(m) + 10, y - 20, { size: 17, weight: 500, color: ENG.label, display: false });
    ctx.restore();
  };
  mark(mu, `${mu} min`, 'as holds here usually end', seg(t, at + 2, at + 2.6));
  mark(p90, `${p90} min`, 'if it drags on (p90)', seg(t, at + 2.8, at + 3.4));
  const hf = lerp(heldFor[0], heldFor[1], seg(t, at, at + 6));
  text(`HELD ${Math.floor(hf)}:${String(Math.floor((hf % 1) * 60)).padStart(2, '0')}`, box.x, box.y - 22, { size: 18, weight: 800, color, spacing: 3, display: false });
  ctx.restore();
}

/** The arrival estimate on a clock axis: a window that tightens onto one time as the ride goes on, a deadline marked. */
function arrivalWindow(t, box, o) {
  const { at, from, to, center, lo, hi, deadline, deadlineLabel, color = C.sky, tighten = [at + 1.5, at + 5] } = o;
  const a = easeOut(seg(t, at, at + 0.8));
  if (a <= 0) return;
  const X = m => box.x + ((m - from) / (to - from)) * box.w, y = box.y + box.h / 2;
  ctx.save(); ctx.globalAlpha *= a;
  ctx.fillStyle = ENG.axis; ctx.fillRect(box.x, y + 60, box.w, 2);
  for (let m = from; m <= to; m += 5) {
    ctx.fillRect(X(m) - 1, y + 54, 2, 12);
    text(clockTxt(m), X(m), y + 96, { size: 18, weight: 500, color: ENG.label, align: 'center', display: false });
  }
  if (deadline != null) {
    ctx.fillStyle = 'rgba(255,122,26,0.8)'; ctx.fillRect(X(deadline) - 1.5, y - 110, 3, 170);
    text(deadlineLabel, X(deadline), y - 124, { size: 20, weight: 700, color: C.late, align: 'center', display: false });
  }
  const k = easeInOut(seg(t, tighten[0], tighten[1]));
  const l = lerp(lo, center - 0.6, k), h = lerp(hi, center + 0.6, k);
  ctx.save(); ctx.shadowColor = color; ctx.shadowBlur = 30;
  rrect(X(l), y - 18, X(h) - X(l), 36, 18); ctx.fillStyle = color + '55'; ctx.fill();
  ctx.strokeStyle = color; ctx.lineWidth = 2; ctx.stroke(); ctx.restore();
  ctx.fillStyle = '#fff'; ctx.beginPath(); ctx.arc(X(center), y, 10, 0, Math.PI * 2); ctx.fill();
  text(clockTxt(center), X(center), y - 40, { size: 40, weight: 800, align: 'center' });
  text(k < 0.5 ? `80% window ${clockTxt(lo)}–${clockTxt(hi)}` : 'window closing in as the train moves', X(center), y + 140, { size: 18, weight: 500, color: ENG.label, align: 'center', display: false });
  ctx.restore();
}

/** Two routes' arrival odds against a deadline: one curve per route, the faster one lit. */
function routeOdds(t, box, o) {
  const { at, from, to, deadline, deadlineLabel, routes, pickAt } = o;   // routes: [{label, mu, sd, color, bullet}]
  const a = easeOut(seg(t, at, at + 0.8));
  if (a <= 0) return;
  const X = m => box.x + ((m - from) / (to - from)) * box.w, base = box.y + box.h;
  ctx.save(); ctx.globalAlpha *= a;
  ctx.fillStyle = ENG.axis; ctx.fillRect(box.x, base, box.w, 2);
  for (let m = from; m <= to; m += 5) text(clockTxt(m), X(m), base + 32, { size: 18, weight: 500, color: ENG.label, align: 'center', display: false });
  const pick = easeInOut(seg(t, pickAt, pickAt + 1));
  routes.forEach((r, i) => {
    const d = easeInOut(seg(t, at + 0.4 + i * 0.8, at + 2 + i * 0.8));
    if (d <= 0) return;
    const p = new Path2D(); p.moveTo(X(from), base);
    for (let m = from; m <= lerp(from, to, d); m += 0.1) p.lineTo(X(m), base - gauss(m, r.mu, r.sd) * box.h * 0.9);
    const area = new Path2D(p); area.lineTo(X(lerp(from, to, d)), base); area.closePath();
    const lit = i === 0 ? 1 - 0.6 * pick : 0.5 + 0.5 * pick;
    ctx.save(); ctx.globalAlpha *= lit;
    ctx.fillStyle = r.color + '30'; ctx.fill(area); glowStroke(p, r.color, 4, 18, 1);
    const pk = base - box.h * 0.9;
    const right = r.mu > deadline, lx = right ? X(r.mu) + 40 : X(r.mu) - 40;
    bullet(right ? lx + 20 : lx - 20, pk + 30, 20, r.bullet, seg(d, 0.6, 1));
    text(r.label, right ? lx + 50 : lx - 50, pk + 38, { size: 22, weight: 700, align: right ? 'left' : 'right', alpha: seg(d, 0.6, 1), display: false });
    text(clockTxt(r.mu), X(r.mu), pk - 20, { size: 30, weight: 800, align: 'center', alpha: seg(d, 0.6, 1) });
    ctx.restore();
  });
  ctx.fillStyle = 'rgba(255,122,26,0.9)'; ctx.fillRect(X(deadline) - 1.5, box.y - 50, 3, box.h + 50);
  text(deadlineLabel, X(deadline), box.y - 64, { size: 22, weight: 700, color: C.late, align: 'center', display: false });
  ctx.restore();
}

/** Express against local: the stations down, time across; the local stops everywhere, the express skips, and the
 *  rider's path changes from one to the other at the cross-platform station with the margin bracketed. */
function expressLocal(t, box, o) {
  const { at, stops, local, express, change, margin } = o;   // local/express: {color, bullet, times: [per stop or null]}
  const a = easeOut(seg(t, at, at + 0.8));
  if (a <= 0) return;
  const tmin = Math.min(...local.times.filter(v => v != null), ...express.times.filter(v => v != null));
  const tmax = Math.max(...local.times.filter(v => v != null), ...express.times.filter(v => v != null));
  const X = m => box.x + 150 + ((m - tmin) / (tmax - tmin)) * (box.w - 150), Y = s => box.y + (s / (stops.length - 1)) * box.h;
  const d = easeInOut(seg(t, at + 0.4, at + 3.4));
  ctx.save(); ctx.globalAlpha *= a;
  stops.forEach((s, i) => {
    ctx.fillStyle = ENG.grid; ctx.fillRect(X(tmin), Y(i), box.w - 150, 1.5);
    text(s, box.x + 130, Y(i) + 6, { size: 19, weight: i === change ? 700 : 500, color: i === change ? C.ink : ENG.label, align: 'right', display: false });
  });
  const line = (sv, mineFrom, mineTo) => {
    const all = new Path2D(), mine = new Path2D(); let st = false, sm = false;
    sv.times.forEach((m, s) => {
      if (m == null) return;
      const x = X(m), y = Y(s);
      st ? all.lineTo(x, y) : all.moveTo(x, y); st = true;
      if (s >= mineFrom && s <= mineTo) { sm ? mine.lineTo(x, y) : mine.moveTo(x, y); sm = true; }
    });
    ctx.save(); ctx.setLineDash([3000 * d, 6000]);
    glowStroke(all, sv.color, 3, 6, 0.45); glowStroke(mine, sv.color, 7, 24, 1);
    ctx.restore();
    sv.times.forEach((m, s) => { if (m != null && d > s / stops.length) { ctx.fillStyle = sv.color; ctx.beginPath(); ctx.arc(X(m), Y(s), 6, 0, Math.PI * 2); ctx.fill(); } });
  };
  line(local, 0, change); line(express, change, stops.length - 1);
  const mk = seg(t, at + 3, at + 3.6);
  if (mk > 0) {
    ctx.save(); ctx.globalAlpha *= mk;
    const x1 = X(local.times[change]), x2 = X(express.times[change]), y = Y(change);
    ctx.strokeStyle = '#fff'; ctx.lineWidth = 2;
    ctx.beginPath(); ctx.moveTo(x1, y - 34); ctx.lineTo(x1, y - 44); ctx.lineTo(x2, y - 44); ctx.lineTo(x2, y - 34); ctx.stroke();
    text(margin, x2 + 24, y - 36, { size: 22, weight: 700, color: C.ok, display: false });
    bullet(X(local.times[0]), Y(0) - 36, 18, local.bullet); bullet(X(express.times[stops.length - 1]) + 34, Y(stops.length - 1), 18, express.bullet);
    ctx.restore();
  }
  ctx.restore();
}

// ---------- the living network, behind the logo ----------
const NETWORK = [
  ['1', [[760, 60], [760, 700], [700, 820], [700, 1020]]], ['4', [[900, 60], [880, 200], [880, 640], [960, 760], [1060, 900], [1060, 1020]]],
  ['A', [[680, 40], [680, 400], [720, 520], [720, 700], [820, 820], [1200, 900], [1560, 900]]], ['F', [[1440, 280], [1100, 400], [840, 500], [800, 660], [860, 800], [860, 1020]]],
  ['N', [[1320, 420], [1000, 470], [860, 560], [840, 720], [780, 880], [620, 1020]]], ['7', [[1620, 380], [1300, 420], [1000, 480], [760, 500]]],
  ['L', [[600, 600], [1000, 620], [1300, 760], [1540, 820]]], ['G', [[1250, 480], [1200, 640], [1100, 760], [960, 900]]],
  ['6', [[980, 40], [960, 200], [940, 600], [900, 700]]], ['J', [[1540, 600], [1200, 700], [980, 720], [900, 740]]],
  ['Q', [[1180, 300], [1020, 360], [900, 560], [920, 860], [980, 1020]]],
].map(([n, pts]) => {
  const P = pts.map(([x, y]) => [(x - 1090) * 1.5 + 960, (y - 540) * 1.15 + 540]);
  const lens = [0]; for (let i = 1; i < P.length; i++) lens.push(lens[i - 1] + Math.hypot(P[i][0] - P[i - 1][0], P[i][1] - P[i - 1][1]));
  const path = new Path2D(); P.forEach(([x, y], i) => (i ? path.lineTo(x, y) : path.moveTo(x, y)));
  return { n, P, lens, len: lens[lens.length - 1], path };
});
function netAt(l, f) {
  const d = clamp(f) * l.len; let i = 1;
  while (i < l.lens.length - 1 && l.lens[i] < d) i++;
  const k = (d - l.lens[i - 1]) / (l.lens[i] - l.lens[i - 1] || 1);
  return [lerp(l.P[i - 1][0], l.P[i][0], k), lerp(l.P[i - 1][1], l.P[i][1], k)];
}
/** The whole network breathing behind the logo: lines, trains moving, and a slow scan of the data the model reads
 *  (stringlines fading through, a pulse along every line). */
function dataField(t, a) {
  if (a <= 0) return;
  ctx.save(); ctx.globalAlpha *= a;
  NETWORK.forEach((l, i) => {
    ctx.save(); ctx.setLineDash([l.len * easeInOut(seg(a, 0, 1)), l.len * 2]);
    glowStroke(l.path, L[l.n], 5, 10, 0.45); ctx.restore();
    const r = rng(i + 50), n = Math.round(l.len / 160);
    for (let k = 0; k < n; k++) {
      const f = ((r() + (k % 2 ? 1 : -1) * t * (0.02 + r() * 0.01)) % 1 + 1) % 1, [x, y] = netAt(l, f);
      ctx.fillStyle = '#fff'; ctx.shadowColor = '#fff'; ctx.shadowBlur = 10; ctx.globalAlpha = a * 0.8;
      ctx.beginPath(); ctx.arc(x, y, 4, 0, Math.PI * 2); ctx.fill();
    }
    ctx.shadowBlur = 0; ctx.globalAlpha = a;
    // a pulse of data running down each line
    const pf = ((t * 0.18 + i * 0.17) % 1), [px, py] = netAt(l, pf);
    const g = ctx.createRadialGradient(px, py, 0, px, py, 60); g.addColorStop(0, 'rgba(156,196,255,0.35)'); g.addColorStop(1, 'rgba(156,196,255,0)');
    ctx.fillStyle = g; ctx.fillRect(px - 60, py - 60, 120, 120);
  });
  // stringlines sweeping across the lower third, as the model reads them
  ctx.save(); ctx.globalAlpha *= 0.28;
  for (let k = 0; k < 26; k++) {
    const x0 = ((k * 90 - t * 60) % (W + 400) + W + 400) % (W + 400) - 200, p = new Path2D();
    for (let s = 0; s <= 8; s++) { const x = x0 + s * 34 + (s > 3 && k % 7 === 3 ? 40 : 0), y = 760 + s * 34; s ? p.lineTo(x, y) : p.moveTo(x, y); }
    ctx.strokeStyle = k % 7 === 3 ? HELD_C : C.sky; ctx.lineWidth = 2; ctx.stroke(p);
  }
  ctx.restore();
  // a dark well behind the tile so the logo reads
  const w = ctx.createRadialGradient(W / 2, 560, 80, W / 2, 560, 700);
  w.addColorStop(0, 'rgba(5,7,13,0.94)'); w.addColorStop(0.5, 'rgba(5,7,13,0.75)'); w.addColorStop(1, 'rgba(5,7,13,0)');
  ctx.fillStyle = w; ctx.fillRect(0, 0, W, H);
  ctx.restore();
}
/** The end card over the living network. */
function endCardData(t, at, line, sub) {
  dataField(t, easeOut(seg(t, at - 0.4, at + 1.4)));
  endCard(t, at, line, sub);
}
