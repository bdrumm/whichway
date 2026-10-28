// Shared by the pickup films: the clock, people, the school, and the app screens the story moves through.
// Each screen takes the film's time t on Pickup's own timeline; other films pass their time mapped onto it.
const AMBER = '#ffb547', WARM = '#ffd89a', HELD = '#ffcc33';

/** An analogue clock at minutes past 3. */
function clock(x, y, r, minutes, alpha = 1, accent = C.ink) {
  if (alpha <= 0) return;
  ctx.save(); ctx.globalAlpha *= alpha; ctx.translate(x, y);
  ctx.fillStyle = 'rgba(255,255,255,0.06)'; ctx.beginPath(); ctx.arc(0, 0, r, 0, Math.PI * 2); ctx.fill();
  ctx.strokeStyle = 'rgba(255,255,255,0.7)'; ctx.lineWidth = r * 0.05; ctx.stroke();
  for (let i = 0; i < 12; i++) {
    const a = i / 12 * Math.PI * 2;
    ctx.beginPath(); ctx.moveTo(Math.sin(a) * r * 0.8, -Math.cos(a) * r * 0.8); ctx.lineTo(Math.sin(a) * r * 0.9, -Math.cos(a) * r * 0.9); ctx.stroke();
  }
  const hA = ((3 + minutes / 60) / 12) * Math.PI * 2, mA = (minutes / 60) * Math.PI * 2;
  ctx.lineCap = 'round';
  ctx.lineWidth = r * 0.07; ctx.beginPath(); ctx.moveTo(0, 0); ctx.lineTo(Math.sin(hA) * r * 0.5, -Math.cos(hA) * r * 0.5); ctx.stroke();
  ctx.strokeStyle = accent; ctx.lineWidth = r * 0.045; ctx.beginPath(); ctx.moveTo(0, 0); ctx.lineTo(Math.sin(mA) * r * 0.78, -Math.cos(mA) * r * 0.78); ctx.stroke();
  ctx.fillStyle = accent; ctx.beginPath(); ctx.arc(0, 0, r * 0.06, 0, Math.PI * 2); ctx.fill();
  ctx.restore();
}
function person(x, y, s, color = '#fff', bag = false) {
  ctx.save(); ctx.fillStyle = color; ctx.shadowColor = WARM; ctx.shadowBlur = 16;
  ctx.beginPath(); ctx.arc(x, y - 52 * s, 15 * s, 0, Math.PI * 2); ctx.fill();
  rrect(x - 16 * s, y - 34 * s, 32 * s, 46 * s, 14 * s); ctx.fill();
  if (bag) { ctx.fillStyle = AMBER; rrect(x + 10 * s, y - 30 * s, 14 * s, 26 * s, 5 * s); ctx.fill(); }
  ctx.restore();
}
function school(t, a, waitK) {
  if (a <= 0) return;
  ctx.save(); ctx.globalAlpha *= a;
  const gx = 1100, gy = 860;
  // the building
  ctx.fillStyle = '#2a2140'; ctx.fillRect(900, 420, 860, 440);
  ctx.beginPath(); ctx.moveTo(880, 430); ctx.lineTo(1330, 300); ctx.lineTo(1780, 430); ctx.closePath(); ctx.fill();
  for (let r = 0; r < 2; r++) for (let c = 0; c < 6; c++) { ctx.fillStyle = 'rgba(255,214,150,0.35)'; rrect(960 + c * 132, 500 + r * 120, 70, 80, 6); ctx.fill(); }
  clock(1330, 380, 46, 30 + 14 * waitK, 1, waitK > 0.3 ? C.red : C.ink);
  // the fence and gate
  ctx.strokeStyle = 'rgba(20,16,30,0.9)'; ctx.lineWidth = 6;
  for (let x = 860; x < 1800; x += 28) { ctx.beginPath(); ctx.moveTo(x, gy - 110); ctx.lineTo(x, gy + 10); ctx.stroke(); }
  ctx.lineWidth = 8; ctx.beginPath(); ctx.moveTo(850, gy - 100); ctx.lineTo(1810, gy - 100); ctx.stroke();
  ctx.fillStyle = '#1a1426'; ctx.fillRect(0, gy + 10, W, H - gy);
  ctx.restore();
}

// ---------- phone screens, each modelled on the app's ----------
const label = (s, x, y) => text(s, x, y, { size: 14, weight: 700, color: C.faint, spacing: 2, display: false });

/** Go tab: the commute picked by its time window, the Now card with the countdown and the 80% arrival window. */
function screenGo(t) {
  text('Go', 32, 120, { size: 34, weight: 700 });
  // commute chips; "School pickup" lights up as its window applies it
  const on = easeOut(seg(t, 7.4, 8.2));
  const w1 = chip(24, 146, 'Work', '#8aa0c8', 1, 18);
  ctx.save(); ctx.globalAlpha *= 1;
  const w2 = measure('School pickup · 2:45–3:15', 18, 600) + 34;
  rrect(24 + w1 + 10, 146, w2, 36, 18); ctx.fillStyle = `rgba(46,124,255,${0.2 + 0.8 * on})`; ctx.fill();
  text('School pickup · 2:45–3:15', 24 + w1 + 27, 165, { size: 18, weight: 600, base: 'middle' });
  ctx.restore();
  const k = easeOut(seg(t, 8.2, 9));
  ctx.save(); ctx.globalAlpha *= k; ctx.translate(0, (1 - k) * 30);
  text('Fulton St  →  Hoyt–Schermerhorn', 32, 222, { size: 19, weight: 500, color: C.dim, display: false });
  screenCard(20, 244, PW - 40, 300);
  label('TAKE THE', 44, 284);
  bullet(84, 344, 38, 'A');
  text('at 3:05', 140, 356, { size: 44, weight: 700 });
  const left = Math.max(0, 420 - (t - 8) * 18), mm = Math.floor(left / 60), ss = String(Math.floor(left % 60)).padStart(2, '0');
  text(`Board in ${mm}:${ss}`, 44, 432, { size: 28, weight: 700, color: C.ok });
  text('Arrive 3:27', 44, 486, { size: 26, weight: 700 });
  text('80% window 3:25–3:30', 44, 518, { size: 18, weight: 500, color: C.dim, display: false });
  ctx.restore();
  // the departure board below
  const b = easeOut(seg(t, 9.6, 10.4));
  ctx.save(); ctx.globalAlpha *= b;
  label('DEPARTURES', 44, 594);
  [['A', '3:05', 'at High St'], ['C', '3:09', 'at Broadway Jct'], ['A', '3:13', 'at Euclid Av']].forEach(([r, at, where], i) => {
    const y = 634 + i * 56;
    bullet(62, y, 18, r); text(at, 92, y + 7, { size: 22, weight: 700 }); text(where, 170, y + 7, { size: 18, weight: 500, color: C.dim, display: false });
  });
  ctx.restore();
}
/** Boarding detection: the motion trace, the candidate trains, the one the phone settles on. */
function sig(s) {
  const walk = 1 - seg(s, 16.2, 16.7), push = Math.exp(-Math.pow((s - 17.6) / 0.8, 2)), ride = seg(s, 17.4, 18.2);
  return clamp(walk * (Math.abs(Math.sin(s * 11)) * 0.9 + noise1(s * 30, 1) * 0.15) + push * 0.75 + ride * (noise1(s * 40, 2) * 0.22) + noise1(s * 50, 4) * 0.03, -1, 1.2);
}
function screenDetect(t) {
  text('Fulton St', 32, 120, { size: 22, weight: 600, color: C.dim, display: false });
  text(t < 18.4 ? 'On the platform' : 'On the train', 32, 162, { size: 34, weight: 700 });
  screenCard(20, 196, PW - 40, 220);
  label('MOTION', 44, 236);
  ctx.save(); ctx.beginPath();
  for (let k = 0; k <= 140; k++) { const v = sig(t - (140 - k) / 20), x = lerp(44, PW - 44, k / 140), y = 330 - v * 55; k ? ctx.lineTo(x, y) : ctx.moveTo(x, y); }
  ctx.lineWidth = 3; ctx.strokeStyle = C.sky; ctx.shadowColor = C.sky; ctx.shadowBlur = 12; ctx.stroke(); ctx.restore();
  const st = t < 16.5 ? ['Walking', C.ice] : t < 17.2 ? ['Standing', C.ice] : t < 18.4 ? ['Train pulling away', C.late] : ['Riding', C.ok];
  chip(44, 374, st[0], st[1], 1, 18);
  const c = easeOut(seg(t, 18.4, 19));
  ctx.save(); ctx.globalAlpha *= c;
  label('WHICH TRAIN?', 44, 466);
  [['A', '3:05', 0.9], ['C', '3:04', 0.07], ['A', '2:57', 0.03]].forEach(([r, at, p], i) => {
    const y = 500 + i * 56, val = lerp(0.33, p, easeInOut(seg(t, 19, 19.8)));
    bullet(62, y + 14, 18, r); text(`left ${at}`, 92, y + 21, { size: 19, weight: 500, color: C.dim, display: false });
    rrect(200, y + 8, 160, 12, 6); ctx.fillStyle = 'rgba(255,255,255,0.08)'; ctx.fill();
    rrect(200, y + 8, 160 * val, 12, 6); ctx.fillStyle = i === 0 ? C.sky : 'rgba(156,196,255,0.45)'; ctx.fill();
  });
  ctx.restore();
  const r = easeOut(seg(t, 19.8, 20.4));
  if (r > 0) {
    ctx.save(); ctx.globalAlpha *= r; ctx.translate(0, (1 - r) * 30);
    rrect(20, 700, PW - 40, 80, 22); ctx.fillStyle = C.blue; ctx.fill();
    bullet(62, 740, 22, 'A');
    text("You're on the 3:05 A", 98, 734, { size: 22, weight: 700 });
    text('Off at Hoyt–Schermerhorn 3:27', 98, 762, { size: 17, weight: 500, color: 'rgba(255,255,255,0.85)', display: false });
    ctx.restore();
  }
}
/** The hold: the Live Activity on the lock screen, then the scenario switch in the app. */
function screenHold(t) {
  const held = easeOut(seg(t, 22.4, 23.2));
  text('Tuesday', PW / 2, 112, { size: 22, weight: 600, color: C.dim, align: 'center', display: false });
  text(t < 22.4 ? '3:08' : '3:10', PW / 2, 210, { size: 88, weight: 300, align: 'center', display: false });
  // Live Activity
  ctx.save();
  rrect(16, 250, PW - 32, 200, 32); ctx.fillStyle = 'rgba(16,22,40,0.94)'; ctx.fill();
  if (held > 0) { ctx.save(); ctx.globalAlpha *= held; ctx.strokeStyle = HELD; ctx.lineWidth = 3; ctx.shadowColor = HELD; ctx.shadowBlur = 18; rrect(16, 250, PW - 32, 200, 32); ctx.stroke(); ctx.restore(); }
  bullet(60, 300, 22, 'A');
  text(held > 0.5 ? 'Held at High St' : "You're on the A", 96, 296, { size: 23, weight: 700, color: held > 0.5 ? HELD : C.ink });
  text('Off at Hoyt–Schermerhorn', 96, 322, { size: 17, weight: 500, color: C.dim, display: false });
  text('ETA', 40, 380, { size: 18, weight: 500, color: C.dim, display: false });
  text(held > 0.5 ? '3:41' : '3:27', 40, 424, { size: 42, weight: 700, color: held > 0.5 ? C.red : C.ink });
  if (held > 0) { ctx.save(); ctx.globalAlpha *= held; const pop = 1 + 0.15 * Math.exp(-Math.pow((t - 23.2) * 5, 2)); ctx.translate(262, 410); ctx.scale(pop, pop); chip(0, -22, '+14 min', C.red, 1, 24); ctx.restore(); }
  ctx.restore();
  // scenario switch
  const s = easeOut(seg(t, 24.6, 25.4));
  if (s > 0) {
    ctx.save(); ctx.globalAlpha *= s; ctx.translate(0, (1 - s) * 30);
    screenCard(20, 480, PW - 40, 330);
    text('A train on this path is held.', 44, 522, { size: 19, weight: 600, display: false });
    text('Times assume the hold…', 44, 548, { size: 17, weight: 500, color: C.dim, display: false });
    const opts = [['ends as usual', '3:41', '3:37–3:46'], ['drags on (p90)', '3:49', ''], ['clears now', '3:30', '']];
    const pick = t < 26.6 ? 0 : t < 27.6 ? 1 : t < 28.6 ? 2 : 0;
    opts.forEach(([name, eta, win], i) => {
      const y = 576 + i * 74, sel = i === pick;
      rrect(36, y, PW - 72, 62, 18); ctx.fillStyle = sel ? 'rgba(255,204,51,0.22)' : 'rgba(255,255,255,0.05)'; ctx.fill();
      if (sel) { ctx.strokeStyle = HELD; ctx.lineWidth = 2; ctx.stroke(); }
      text(name, 56, y + 38, { size: 20, weight: 600, color: sel ? C.ink : C.dim, display: false });
      text(eta, PW - 56, y + 30, { size: 24, weight: 700, align: 'right', color: sel ? HELD : C.dim });
      if (win) text(win, PW - 56, y + 52, { size: 14, weight: 500, align: 'right', color: C.faint, display: false });
    });
    ctx.restore();
  }
}
function screenMessages(t) {
  text('Sam', PW / 2, 120, { size: 26, weight: 700, align: 'center' });
  const bubble = (s, mine, y, at, w) => {
    const k = easeOut(seg(t, at, at + 0.5));
    if (k <= 0) return;
    ctx.save(); ctx.globalAlpha *= k; ctx.translate(0, (1 - k) * 20);
    const lines = s.split('\n'), h = 30 + lines.length * 28;
    const x = mine ? PW - 24 - w : 24;
    rrect(x, y, w, h, 22); ctx.fillStyle = mine ? C.blue : 'rgba(255,255,255,0.14)'; ctx.fill();
    lines.forEach((l, i) => text(l, x + 20, y + 38 + i * 28, { size: 20, weight: 500, display: false }));
    ctx.restore();
  };
  bubble('My A is held. WhichWay\nhas me in at 3:41, 3:49\nat worst. Could you grab\nMaya with yours?', true, 170, 38.2, 316);
  const typing = seg(t, 40.2, 40.4) * (1 - seg(t, 41.6, 41.8));
  if (typing > 0) {
    ctx.save(); ctx.globalAlpha *= typing; rrect(24, 360, 90, 50, 22); ctx.fillStyle = 'rgba(255,255,255,0.14)'; ctx.fill();
    for (let i = 0; i < 3; i++) { ctx.fillStyle = `rgba(255,255,255,${0.4 + 0.5 * Math.max(0, Math.sin(t * 8 - i))})`; ctx.beginPath(); ctx.arc(50 + i * 20, 385, 6, 0, Math.PI * 2); ctx.fill(); }
    ctx.restore();
  }
  bubble("Of course. I'm at the\ngate already. Got her.", false, 360, 41.8, 290);
  bubble("We'll be at the park.", false, 476, 42.8, 230);
  bubble('Thank you!!', true, 550, 43.6, 150);
}
function screenArrived(t) {
  const k = easeOut(seg(t, 45.2, 46));
  ctx.save(); ctx.globalAlpha *= k;
  ctx.shadowColor = C.ok; ctx.shadowBlur = 40;
  ctx.fillStyle = C.ok; ctx.beginPath(); ctx.arc(PW / 2, 300, 66 * expoOut(k), 0, Math.PI * 2); ctx.fill(); ctx.shadowBlur = 0;
  ctx.strokeStyle = '#08321f'; ctx.lineWidth = 12; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
  ctx.setLineDash([140 * easeOut(seg(t, 45.6, 46.4)), 300]);
  ctx.beginPath(); ctx.moveTo(PW / 2 - 30, 302); ctx.lineTo(PW / 2 - 6, 326); ctx.lineTo(PW / 2 + 34, 276); ctx.stroke(); ctx.setLineDash([]);
  text('Hoyt–Schermerhorn', PW / 2, 430, { size: 24, weight: 600, color: C.dim, align: 'center', display: false });
  text('Arrived 3:41', PW / 2, 486, { size: 42, weight: 700, align: 'center' });
  text('Predicted at 3:10: 3:41', PW / 2, 530, { size: 21, weight: 600, color: C.ok, align: 'center', display: false });
  ctx.restore();
}

