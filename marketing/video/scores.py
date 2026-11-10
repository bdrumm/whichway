#!/usr/bin/env python3
"""Scores for the short films, from one small synthesiser: a pad, plucked arpeggios, kick, hats, bass, a riser
and a final chord with bells, laid out per film by a spec.

    python3 scores.py minutes out.wav       # or livingmap, newyorker (needs numpy)
"""
import sys
import wave

import numpy as np

SR = 44100


def hz(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def ramp(t, pts):
    xs, ys = zip(*pts)
    return np.interp(t, xs, ys)


SPECS = {
    # warm, unhurried: F - C/E - Dm - Bb, a felt-piano pluck, a heartbeat kick only when the city lights up
    'minutes': dict(
        dur=47, beat=0.75, bar=3.0, hit=40.4, bells=[(84, 42.5), (89, 43.2)],
        chords=[[41, 53, 57, 60, 65], [40, 52, 55, 60, 64], [38, 50, 53, 57, 62], [34, 50, 53, 58, 62]],
        hit_notes=[29, 41, 53, 60, 65, 69, 72, 77],
        pad=[(0, 0.5), (12, 0.7), (34, 1.0), (40, 1.1)],
        arp=dict(start=1.0, sub=[(0, 1), (13, 2)], vel=[(1, 0.5), (19, 0.7), (34, 1.0)], soft=True),
        kick=(34.0, 0.5), hats=None, bass=(19.8, 0.5), riser=2.0,
    ),
    # awe and scale: Am - F - C - G at 110 bpm, a running 16th pulse, the band from the zoom, a lift at the core
    'livingmap': dict(
        dur=48, beat=60 / 110, bar=4 * 60 / 110 * 2, hit=42.0, bells=[(88, 44.1), (95, 44.8)],
        chords=[[45, 57, 60, 64, 69], [41, 57, 60, 65, 69], [48, 55, 60, 64, 67], [43, 55, 59, 62, 67]],
        hit_notes=[36, 48, 55, 60, 64, 67, 72, 76],
        pad=[(0, 0.6), (15, 0.8), (25, 0.7), (33, 1.1), (42, 1.1)],
        arp=dict(start=4.0, sub=[(0, 4)], vel=[(4, 0.35), (15, 0.7), (25, 0.55), (33, 1.0)], soft=False),
        kick=(15.0, 0.9), hats=(25.0, 0.8), bass=(15.0, 1.0), riser=2.4,
    ),
    # hope: C - G/B - Am - F at 92 bpm; a quiet start, a pulse once the first ride works, a hush at day 100
    'newyorker': dict(
        dur=47, beat=60 / 92, bar=4 * 60 / 92, hit=42.2, bells=[(84, 44.3), (91, 45.0)],
        chords=[[36, 52, 55, 60, 64], [35, 50, 55, 59, 62], [33, 52, 57, 60, 64], [29, 53, 57, 60, 65]],
        hit_notes=[24, 36, 48, 55, 60, 64, 67, 72, 76],
        pad=[(0, 0.4), (6, 0.7), (21.6, 0.9), (33.8, 0.6), (39.6, 1.0)],
        arp=dict(start=1.0, sub=[(0, 1), (6.6, 2), (21.6, 4), (33.8, 1), (37, 2)],
                 vel=[(1, 0.45), (13.8, 0.65), (27.8, 0.9), (33.8, 0.5), (39, 1.0)], soft=True),
        kick=(21.6, 0.7), hats=(27.8, 0.6), bass=(21.6, 0.8), riser=3.0,
        mute=[(33.6, 37.0)],  # drums and bass drop out for "someone asks you which way"
    ),
    # a story: calm ride, the hold (pulse stops), the ask, relief; Eb - Bb - Cm - Ab at 96 bpm
    'pickup': dict(
        dur=60, beat=60 / 96, bar=4 * 60 / 96, hit=54.8, bells=[(87, 56.9), (94, 57.6)],
        chords=[[39, 55, 58, 63, 67], [34, 53, 58, 62, 65], [36, 55, 60, 63, 67], [32, 56, 60, 63, 68]],
        hit_notes=[27, 39, 51, 58, 63, 67, 70, 75, 79],
        pad=[(0, 0.5), (7, 0.7), (22.4, 0.9), (30, 0.7), (37.4, 0.8), (45, 1.0), (54, 1.1)],
        arp=dict(start=6.6, sub=[(0, 2), (22.4, 1), (37.4, 2), (41.8, 4)],
                 vel=[(6.6, 0.55), (22.4, 0.4), (37.4, 0.6), (41.8, 0.9), (45, 1.0)], soft=True),
        kick=(14.8, 0.55), hats=(45.0, 0.6), bass=(14.8, 0.7), riser=2.4,
        mute=[(22.4, 41.8)],  # the pulse stops with the train and comes back with Sam's answer
    ),
    # Maya: a music-box gate, a hush under Brooklyn, warmth when Sam comes, a swell on the hug; Db - Ab/C - Bbm - Gb
    'maya': dict(
        dur=60, beat=60 / 84, bar=4 * 60 / 84, hit=54.8, bells=[(85, 56.9), (92, 57.6)],
        chords=[[37, 53, 56, 61, 65], [36, 51, 56, 60, 63], [34, 53, 58, 61, 65], [30, 54, 58, 61, 66]],
        hit_notes=[25, 37, 49, 56, 61, 65, 68, 73, 77],
        pad=[(0, 0.5), (13.4, 0.8), (24.8, 0.6), (33, 0.8), (37.6, 1.0), (48.2, 1.2), (54, 1.1)],
        arp=dict(start=0.8, sub=[(0, 2), (13.4, 1), (33, 2), (42.2, 4)],
                 vel=[(0.8, 0.5), (13.4, 0.35), (33, 0.6), (42.2, 0.85), (48.2, 1.0)], soft=True),
        kick=(42.2, 0.45), hats=None, bass=(33.0, 0.6), riser=2.2,
    ),
    # Curtain: a tender opening, anxious and sparse when the 2 crawls, a lift with the faster way, a hush in the
    # theatre and a swell on Leo's line; F - Dm - Bb - C at 100 bpm
    'curtain': dict(
        dur=60, beat=0.6, bar=2.4, hit=54.8, bells=[(84, 56.9), (89, 57.6)],
        chords=[[41, 57, 60, 65, 69], [38, 57, 62, 65, 69], [34, 58, 62, 65, 70], [36, 55, 60, 64, 67]],
        hit_notes=[29, 41, 53, 60, 65, 69, 72, 77, 81],
        pad=[(0, 0.5), (14.8, 0.8), (22.2, 0.9), (37.8, 0.6), (44.4, 0.9), (48, 1.2), (54, 1.1)],
        arp=dict(start=0.6, sub=[(0, 2), (14.8, 1), (22.2, 4), (37.8, 1), (44.4, 2)],
                 vel=[(0.6, 0.5), (14.8, 0.4), (22.2, 0.9), (37.8, 0.45), (48, 1.0)], soft=True),
        kick=(22.2, 0.6), hats=(26.0, 0.5), bass=(22.2, 0.7), riser=2.2,
        mute=[(37.8, 48.0)],  # the theatre goes quiet until Leo's line
    ),
}
# Under the Clock: single notes falling like the dots on the board, a pulse when the city draws itself, a hush for
# 1986, sparse and uneasy while the 6 holds, a lift when he crosses the platform and a swell when she arrives;
# D - A/C# - Bm - G at 80 bpm, ending on the signature chime
SPECS['clock'] = dict(
    dur=72, beat=0.75, bar=3.0, hit=65.2, bells=[], chime=62,
    chords=[[38, 54, 57, 62, 66], [37, 52, 57, 61, 64], [35, 54, 59, 62, 66], [31, 55, 59, 62, 67]],
    hit_notes=[26, 38, 50, 57, 62, 66, 69, 74, 78],
    pad=[(0, 0.35), (9.4, 0.7), (12.6, 0.9), (22.2, 0.55), (31.8, 0.8), (35.6, 0.5), (48.6, 0.7), (51.4, 0.95),
         (58, 0.9), (61, 1.25), (65, 1.1)],
    arp=dict(start=0.9, sub=[(0, 1), (6.2, 2), (12.6, 4), (22.2, 1), (31.8, 2), (35.6, 1), (51.4, 2), (54.4, 2), (61, 4)],
             vel=[(0.9, 0.5), (9, 0.75), (12.6, 0.9), (22.2, 0.45), (33, 0.6), (38, 0.4), (51.4, 0.8), (61, 1.0)], soft=True),
    kick=(12.6, 0.5), hats=None, bass=(12.6, 0.7), riser=2.4,
    mute=[(22.2, 51.4), (54.4, 61.0)],  # the pulse stops for 1986 and the hold, returns as he crosses, and again when she arrives
)
# Under the Clock, live-action cut: the same key on a 96 bpm grid the picture is cut to, with what a trailer needs:
# booms on the cuts, a brake squeal into the stop, a heartbeat and a ticking clock through the hold, swells into
# the memory and into the run, the band back when he crosses the platform and at full height for the promise kept
SPECS['clock-live'] = dict(
    dur=87.5, beat=0.625, bar=2.5, hit=80.2, bells=[], chime=62,
    chords=SPECS['clock']['chords'], hit_notes=SPECS['clock']['hit_notes'],
    pad=[(0, 0.5), (5, 0.6), (12.3, 0.9), (13.75, 1.0), (22.5, 0.6), (27.5, 0.7), (37.5, 0.95), (42.5, 0.6), (46.25, 0.7),
         (48.6, 0.7), (48.7, 0.25), (56.25, 0.5), (59.3, 0.6), (59.4, 1.0), (65, 0.8), (71.25, 1.3), (80, 1.1)],
    arp=dict(start=0.6, sub=[(0, 1), (5, 2), (13.75, 4), (22.5, 1), (27.5, 2), (32.5, 1), (37.5, 2), (42.5, 2), (46.25, 4),
                             (48.65, 1), (59.4, 4), (65, 2), (71.25, 4)],
             vel=[(0.6, 0.5), (5, 0.6), (12, 0.8), (13.75, 0.95), (22.4, 0.9), (22.5, 0.45), (37.5, 0.7), (42.5, 0.5),
                  (46.25, 0.8), (48.6, 0.85), (48.7, 0.0), (51.2, 0.0), (51.3, 0.3), (59.3, 0.35), (59.4, 0.95), (65, 0.6),
                  (71.25, 1.0)], soft=True),
    kick=(13.75, 0.8), hats=(13.75, 0.6), bass=(13.75, 0.9), riser=2.4,
    mute=[(22.5, 46.25), (48.65, 59.4), (65.0, 71.25)],
    impacts=[(5, 0.6), (13.75, 0.8), (22.5, 0.5), (27.5, 0.5), (42.5, 0.7), (48.65, 1.2), (49.5, 1.0), (59.4, 1.0), (65, 0.9),
             (71.25, 0.8)],
    heart=[(49.6, 59.0)], ticks=[(32.5, 36.25, 0.625), (36.25, 37.5, 0.15625), (51.25, 59.3, 0.625)],
    whoosh=[(26.6, 27.5), (41.7, 42.5), (58.4, 59.4), (63.6, 65.0)], brake=(47.4, 48.65),
)
# engine cuts: the same scores, ending on the signature chime instead of the plucked bells
SPECS['maya-engine'] = dict(SPECS['maya'], chime=61)
SPECS['curtain-engine'] = dict(SPECS['curtain'], chime=65)


class Score:
    def __init__(self, spec):
        self.s = spec
        self.n = int(spec['dur'] * SR)
        self.t = np.arange(self.n) / SR
        self.rng = np.random.default_rng(9)

    def chord(self, t):
        return self.s['chords'][int(t // self.s['bar']) % len(self.s['chords'])]

    def add(self, buf, at, sig, gain=(1.0, 1.0)):
        i0 = int(at * SR)
        if i0 >= self.n:
            return
        sig = sig[: self.n - i0]
        buf[i0:i0 + len(sig), 0] += sig * gain[0]
        buf[i0:i0 + len(sig), 1] += sig * gain[1]

    def pad(self):
        out = np.zeros((self.n, 2))
        bar, hit = self.s['bar'], self.s['hit']
        c = 0
        while c * bar < hit:
            t0 = c * bar
            length = min(bar + 0.6, hit - t0 + 0.4)
            t = np.arange(int(length * SR)) / SR
            e = np.minimum(1, t / 1.0) * np.clip((length - t) / 0.7, 0, 1)
            for side, det in ((0, -0.07), (1, 0.07)):
                sig = np.zeros(len(t))
                for m in self.chord(t0)[1:]:
                    f = hz(m) * 2 ** (det / 12)
                    for h, a in ((1, 1.0), (2, 0.3), (3, 0.12)):
                        sig += a * np.sin(2 * np.pi * f * h * t + self.rng.uniform(0, 6))
                i0 = int(t0 * SR)
                seg = (sig * e)[: self.n - i0]
                out[i0:i0 + len(seg), side] += seg
            c += 1
        return out * 0.03 * ramp(self.t, self.s['pad'])[:, None]

    def pluck(self, f, length, soft):
        t = np.arange(int(length * SR)) / SR
        if soft:  # felt piano: rounder, longer
            s = np.sin(2 * np.pi * f * t) + 0.18 * np.sin(4 * np.pi * f * t) + 0.05 * np.sin(6 * np.pi * f * t)
            return s * np.exp(-t * 3.2) * np.minimum(1, t / 0.008)
        s = np.sin(2 * np.pi * f * t) + 0.3 * np.sin(4 * np.pi * f * t) + 0.08 * np.sin(6 * np.pi * f * t)
        return s * np.exp(-t * 7) * np.minimum(1, t / 0.003)

    def arp(self):
        a = self.s['arp']
        out = np.zeros((self.n, 2))
        pattern = [0, 2, 3, 4, 3, 2, 4, 1]
        t, k = a['start'], 0
        while t < self.s['hit'] - 0.1:
            sub = [v for at, v in a['sub'] if at <= t][-1]
            m = self.chord(t)[pattern[k % 8]] + 12
            vel = float(ramp(t, a['vel'])) * (1.0 if k % 2 == 0 else 0.75)
            pan = 0.5 + 0.35 * np.sin(k * 0.9)
            self.add(out, t, self.pluck(hz(m), 1.4 if a['soft'] else 0.9, a['soft']) * vel, (1 - pan, pan))
            t += self.s['beat'] / sub
            k += 1
        return out * 0.11

    def muted(self, t):
        return any(a <= t < b for a, b in self.s.get('mute', []))

    def drums(self):
        out = np.zeros((self.n, 2))
        if self.s['kick']:
            start, vol = self.s['kick']
            t = start
            while t < self.s['hit'] - 0.3:
                if not self.muted(t):
                    kt = np.arange(int(0.45 * SR)) / SR
                    ph = 2 * np.pi * np.cumsum(48 + 90 * np.exp(-kt * 30)) / SR
                    self.add(out, t, np.sin(ph) * np.exp(-kt * 7) * vol * 0.3)
                t += self.s['beat']
        if self.s['hats']:
            start, vol = self.s['hats']
            t = start + self.s['beat'] / 2
            while t < self.s['hit'] - 0.3:
                if not self.muted(t):
                    hn = int(0.06 * SR)
                    hat = np.diff(self.rng.standard_normal(hn + 1)) * np.exp(-np.arange(hn) / SR * 60) * 0.022 * vol
                    self.add(out, t, hat)
                t += self.s['beat']
        return out

    def bass(self):
        out = np.zeros((self.n, 2))
        if not self.s['bass']:
            return out
        start, vol = self.s['bass']
        bar = self.s['bar']
        t0 = np.floor(start / bar) * bar
        while t0 < self.s['hit']:
            length = min(bar, self.s['hit'] - t0)
            t = np.arange(int(length * SR)) / SR
            pulse = 0.55 + 0.45 * np.abs(np.sin(np.pi * t / (self.s['beat'] / 2)))
            s = np.tanh(1.5 * np.sin(2 * np.pi * hz(self.chord(t0)[0]) * t)) * pulse
            s *= np.minimum(1, t / 0.05) * np.clip((length - t) / 0.05, 0, 1)
            if t0 + 0.01 >= start and not self.muted(t0 + 0.01):
                self.add(out, t0, s * vol * 0.065)
            t0 += bar
        return out

    def riser(self):
        out = np.zeros((self.n, 2))
        a, b = self.s['hit'] - self.s['riser'], self.s['hit']
        n = int((b - a) * SR)
        k = np.arange(n) / n
        noise = self.rng.standard_normal(n)
        sm = np.convolve(noise, np.ones(24) / 24, mode='same')
        s = (sm * (1 - k) + noise * k * 0.15) * k ** 2
        self.add(out, a, s * 0.02)
        return out

    def hit(self):
        out = np.zeros((self.n, 2))
        hit, dur = self.s['hit'], self.s['dur']
        length = dur - hit
        t = np.arange(int(length * SR)) / SR
        e = np.exp(-t * 0.45) * np.minimum(1, t / 0.01) * np.clip((length - t) / 1.2, 0, 1)
        for side, det in ((0, -0.05), (1, 0.05)):
            sig = np.zeros(len(t))
            for i, m in enumerate(self.s['hit_notes']):
                f = hz(m) * 2 ** (det / 12)
                for h, a in ((1, 1.0), (2, 0.3), (3, 0.12)):
                    sig += (1.4 if i == 0 else 1.0) * a * np.sin(2 * np.pi * f * h * t + self.rng.uniform(0, 6))
            i0 = int(hit * SR)
            seg = (sig * e)[: self.n - i0]
            out[i0:i0 + len(seg), side] += seg * 0.085
        if 'chime' in self.s:
            return out * 0.6 + self.chime()
        kt = np.arange(int(0.45 * SR)) / SR
        ph = 2 * np.pi * np.cumsum(48 + 90 * np.exp(-kt * 30)) / SR
        self.add(out, hit, np.sin(ph) * np.exp(-kt * 7) * 0.2)
        for m, at in self.s['bells']:
            self.add(out, at, self.pluck(hz(m), 3.0, False) * 0.02)
        return out

    def bell(self, f, length, index=2.2):
        """An FM bell: an inharmonic modulator with a decaying index, so it strikes bright and settles pure."""
        t = np.arange(int(length * SR)) / SR
        idx = index * np.exp(-t * 2.4)
        s = np.sin(2 * np.pi * f * t + idx * np.sin(2 * np.pi * f * 1.4 * t))
        s += 0.25 * np.sin(2 * np.pi * f * 2.76 * t) * np.exp(-t * 5)
        return s * np.exp(-t * 1.1) * np.minimum(1, t / 0.004)

    def chime(self):
        """The WhichWay signature: three bells timed to the icon drawing itself (stem, branch, dot), the last one
        highest, with a shimmer above and a sine an octave below."""
        out = np.zeros((self.n, 2))
        root, hit = self.s['chime'], self.s['hit']
        left = self.s['dur'] - hit
        for (iv, dt, g, pan) in ((0, 0.45, 0.05, -0.3), (7, 1.05, 0.05, 0.3), (16, 2.05, 0.065, 0.0)):
            f = hz(root + iv)
            sig = self.bell(f, left - dt)
            if iv == 16:
                t = np.arange(len(sig)) / SR
                sig = sig + 0.35 * np.sin(2 * np.pi * f / 2 * t) * np.exp(-t * 0.6) * np.minimum(1, t / 0.05)
                sig = sig + 0.12 * self.bell(f * 2, left - dt, 1.2) * np.sin(2 * np.pi * 5.5 * t) ** 2
            self.add(out, hit + dt, sig * g, gain=(1 - pan, 1 + pan))
        return out

    def fx(self):
        """Trailer furniture, laid out by the spec: `impacts` (a boom at each time), `heart` (a heartbeat over each
        range), `ticks` (a clock over each range at an interval), `whoosh` (a swell that peaks at the end of each range)
        and `brake` (a squeal falling to a stop)."""
        out = np.zeros((self.n, 2))
        s = self.s
        for at, g in s.get('impacts', []):
            t = np.arange(int(2.4 * SR)) / SR
            boom = np.sin(2 * np.pi * np.cumsum(34 + 60 * np.exp(-t * 9)) / SR) * np.exp(-t * 1.8)
            crack = np.convolve(self.rng.standard_normal(len(t)), np.ones(40) / 40, mode='same') * np.exp(-t * 7) * 2.0
            self.add(out, at, (boom + crack) * np.minimum(1, t / 0.003) * 0.22 * g)
        for a, b in s.get('heart', []):
            t0 = a
            while t0 < b:
                for dt, g in ((0.0, 1.0), (0.27, 0.7)):
                    t = np.arange(int(0.4 * SR)) / SR
                    thump = np.sin(2 * np.pi * np.cumsum(46 + 40 * np.exp(-t * 28)) / SR) * np.exp(-t * 11)
                    self.add(out, t0 + dt, thump * 0.2 * g * float(ramp(t0, [(a, 0.6), (b, 1.0)])))
                t0 += 1.0
        for a, b, iv in s.get('ticks', []):
            t0, k = a, 0
            while t0 < b - 0.01:
                t = np.arange(int(0.05 * SR)) / SR
                f = 2100 if k % 2 == 0 else 1700
                tick = (np.sin(2 * np.pi * f * t) + 0.5 * np.sin(2 * np.pi * f * 2.3 * t)) * np.exp(-t * 160)
                pan = 0.4 if k % 2 == 0 else 0.6
                self.add(out, t0, tick * 0.05, (1 - pan, pan))
                t0 += iv
                k += 1
        for a, b in s.get('whoosh', []):
            n = int((b - a) * SR)
            k = np.arange(n) / n
            noise = np.convolve(self.rng.standard_normal(n), np.ones(18) / 18, mode='same')
            self.add(out, a, noise * k ** 3 * 0.11)
        if 'brake' in s:
            a, b = s['brake']
            n = int((b - a) * SR)
            k = np.arange(n) / n
            ph = 2 * np.pi * np.cumsum(1900 - 1300 * k ** 1.5) / SR
            squeal = (np.sin(ph) + 0.4 * np.sin(1.51 * ph)) * (0.6 + 0.4 * np.sin(2 * np.pi * 31 * k * (b - a)))
            rumble = np.convolve(self.rng.standard_normal(n), np.ones(120) / 120, mode='same') * 6
            self.add(out, a, (squeal * 0.022 + rumble * 0.05) * np.sin(np.pi * k) ** 0.7 * (1 - k * 0.3))
        return out

    def reverb(self, x, mix=0.35):
        n = self.n
        out = np.zeros_like(x)
        for ch in range(2):
            s = x[:, ch]
            acc = np.zeros(n)
            for d_ms, g in ((29.7, 0.8), (37.1, 0.79), (41.1, 0.78), (43.7, 0.77)):
                d = int(d_ms * SR / 1000) + ch * 23
                y = s.copy()
                for i in range(d, n, d):
                    j = min(i + d, n)
                    y[i:j] += g * y[i - d:j - d]
                acc += y
            for d_ms, g in ((5.0, 0.7), (1.7, 0.7)):
                d = int(d_ms * SR / 1000)
                y = np.zeros(n)
                for i in range(0, n, d):
                    j = min(i + d, n)
                    prev_in = acc[i - d:j - d] if i >= d else np.zeros(j - i)
                    prev_out = y[i - d:j - d] if i >= d else np.zeros(j - i)
                    y[i:j] = -g * acc[i:j] + prev_in + g * prev_out
                acc = y
            out[:, ch] = acc * 0.25
        return x * (1 - mix) + out * mix

    def render(self):
        mixed = self.reverb(self.pad() + self.arp() + self.hit()) + self.drums() + self.bass() + self.riser()
        mixed += self.fx() * 0.6 + self.reverb(self.fx(), 0.6) * 0.5
        dur = self.s['dur']
        mixed *= ramp(self.t, [(0, 0), (1.2, 1), (dur - 1.0, 1), (dur, 0)])[:, None]
        mixed = np.tanh(mixed * 2.2)
        return mixed / (np.max(np.abs(mixed)) / 0.89)


def main(name, path):
    pcm = (Score(SPECS[name]).render() * 32767).astype(np.int16)
    with wave.open(path, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
