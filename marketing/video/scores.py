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
# Under the Clock, illustrated cut: the story first, so the score carries it. No noise: every effect is made of notes
# from the chord under it (see Score.fx2). Rain is high plucked drops, the hall's clock ticks in key, a train is rail
# joints on the root and brakes as the chord running down like a record stopping, the city talking is a shower of
# glass notes, the trains ahead answer up a scale, the doors chime, and the film ends on the logo sound (Score.logo)
SPECS['clock-nyc'] = dict(
    dur=90, beat=0.625, bar=2.5, hit=82.7, bells=[], logo=62, riser=None,
    chords=SPECS['clock']['chords'], hit_notes=SPECS['clock']['hit_notes'],
    pad=[(0, 0.5), (5, 0.7), (12.5, 0.5), (15.6, 0.3), (20, 0.45), (22.5, 0.7), (27.2, 1.0), (30, 0.95), (36.4, 1.1), (40, 0.55),
         (43.75, 0.4), (46.9, 0.3), (48.75, 0.5), (53.75, 0.6), (56.9, 0.95), (62.5, 0.6), (68.75, 0.75), (73.2, 1.35), (79, 1.1),
         (82.7, 1.0)],
    arp=dict(start=0.6, sub=[(0, 1), (5, 2), (12.5, 4), (14.5, 1), (22.5, 4), (25, 2), (30, 4), (40, 1), (43.75, 2), (46.15, 1),
                             (48.75, 2), (56.9, 4), (62.5, 1), (68.75, 2), (73.2, 4)],
             vel=[(0.6, 0.5), (5, 0.65), (12.4, 0.7), (12.5, 0.8), (14.4, 0.8), (14.5, 0.0), (19.9, 0.0), (20, 0.4), (22.4, 0.45),
                  (22.5, 0.8), (25, 0.6), (27.2, 0.9), (30, 0.95), (39.9, 1.0), (40, 0.5), (43.75, 0.55), (46.1, 0.6), (46.15, 0.0),
                  (48.7, 0.0), (48.75, 0.35), (53.75, 0.5), (56.9, 0.9), (62.4, 0.95), (62.5, 0.45), (68.75, 0.6), (73.1, 0.8),
                  (73.2, 1.0)], soft=True),
    kick=(30, 0.8), hats=(30, 0.6), bass=(30, 0.9),
    mute=[(40, 56.9), (62.5, 73.2)],  # the band stops with the train, returns as he crosses, holds its breath while he waits
    blooms=[(5, 0.6), (12.5, 0.8), (15.625, 0.9), (22.5, 0.8), (27.2, 1.0), (30, 1.1), (36.4, 1.0), (40, 0.6), (43.75, 0.7),
            (46.875, 1.1), (52.9, 0.6), (56.9, 1.0), (58.75, 0.8), (62.5, 0.8), (68.75, 0.5), (73.2, 1.2), (76.25, 0.5)],
    swells=[(4.2, 5), (21.6, 22.5), (26.2, 27.2), (29.0, 30), (35.6, 36.4), (51.0, 52.9), (56.0, 56.9), (61.6, 62.5), (72.0, 73.2),
            (80.6, 82.7)],
    bends=[(13.3, 14.5), (44.9, 46.15)], rides=[(12.5, 13.3, 14.5), (43.75, 44.9, 46.15), (58.75, 62.5, 62.5)],
    clock=[(8.4, 12.2, 0.3125, 0.8), (15.625, 20, 0.625, 1.0), (47.0, 53.7, 0.625, 0.9), (62.9, 68.7, 0.625, 0.7)],
    pulse=[(20, 22.5), (46.875, 53.75)],
    pings=[(30.5, 36.4, 0.15, 1.0), (36.4, 40, 1.2, 1.0), (48.75, 53.75, 0.5, 0.7), (76.25, 82.5, 0.2, 0.6)],
    reports=[(49.4, 0.3125, 6)], drops=[(0.3, 5, 5), (40, 43.75, 6)], doors=[58.3], gliss=[(26.7, 0.6, 0.8), (72.6, 0.8, 1.0)],
    notify=[54.7],
)
# the logo sounds on their own, for choosing between and for reuse: python3 scores.py logo-fork out.wav (see Score.logo)
LOGOS = ('fork', 'rails', 'chime', 'swell', 'heart')
for _style in LOGOS:
    SPECS['logo-' + _style] = dict(dur=6.5, beat=0.625, bar=2.5, hit=0.3, logo=62, logo_style=_style, chords=SPECS['clock']['chords'])
# and the score-born effects one at a time (sounds.html names them): python3 scores.py effects out.wav
SPECS['effects'] = dict(
    dur=42, beat=0.625, bar=2.5, hit=42, chords=SPECS['clock']['chords'],
    blooms=[(0.5, 1.0), (5.0, 1.0), (35.9, 1.0)], swells=[(3.6, 5.0)], rides=[(7.2, 8.6, 9.8)], bends=[(8.6, 9.8)],
    clock=[(11.2, 14.0, 0.625, 1.0)], pulse=[(14.7, 18.2)], pings=[(18.7, 23.5, 0.2, 1.2)], reports=[(24.5, 0.3125, 6)],
    drops=[(27.7, 31.2, 6)], doors=[32.0], gliss=[(35.1, 0.8, 1.0)], notify=[39.0],
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
        if 'pad' not in self.s:
            return out
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
        out = np.zeros((self.n, 2))
        if 'arp' not in self.s:
            return out
        a = self.s['arp']
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
        if self.s.get('kick'):
            start, vol = self.s['kick']
            t = start
            while t < self.s['hit'] - 0.3:
                if not self.muted(t):
                    kt = np.arange(int(0.45 * SR)) / SR
                    ph = 2 * np.pi * np.cumsum(48 + 90 * np.exp(-kt * 30)) / SR
                    self.add(out, t, np.sin(ph) * np.exp(-kt * 7) * vol * 0.3)
                t += self.s['beat']
        if self.s.get('hats'):
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
        if not self.s.get('bass'):
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
        if not self.s.get('riser'):
            return out
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
        if 'hit_notes' not in self.s:
            return out
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
        if 'logo' in self.s:
            return out * 0.4 + self.logo()
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

    def mallet(self, f, length=1.2, decay=4.5):
        """Warm wood: the fundamental, with a fourth partial and a tenth that die at once."""
        t = np.arange(int(length * SR)) / SR
        s = np.sin(2 * np.pi * f * t) * np.exp(-t * decay) + 0.25 * np.sin(2 * np.pi * 4 * f * t) * np.exp(-t * decay * 3.2)
        s += 0.07 * np.sin(2 * np.pi * 10 * f * t) * np.exp(-t * decay * 7)
        return s * np.minimum(1, t / 0.004)

    def glide(self, f0, f1, length, bend=0.35, decay=1.2, rich=0.2):
        """A struck note that bends from f0 to f1 over its first `bend` seconds and rings on."""
        t = np.arange(int(length * SR)) / SR
        k = np.clip(t / bend, 0, 1)
        k = k * k * (3 - 2 * k)
        ph = 2 * np.pi * np.cumsum(f0 * (f1 / f0) ** k) / SR
        s = np.sin(ph) + rich * np.sin(2 * ph) + rich * 0.3 * np.sin(3 * ph)
        return s * np.exp(-t * decay) * np.minimum(1, t / 0.012)

    def strings(self, f, length, attack=0.5, release=1.5):
        """A bowed, breathing voice: eight partials rolling off, a little vibrato once it has settled."""
        t = np.arange(int(length * SR)) / SR
        ph = 2 * np.pi * np.cumsum(f * (1 + 0.003 * np.sin(2 * np.pi * 5.1 * t) * np.minimum(1, t / 0.8))) / SR
        s = sum(np.sin(h * ph + self.rng.uniform(0, 6)) / h ** 1.5 for h in range(1, 9))
        return s * np.minimum(1, t / attack) * np.exp(-np.maximum(0, t - attack) * 0.45) * np.clip((length - t) / release, 0, 1)

    def logo(self):
        """The WhichWay logo sound, timed to the icon drawing itself (stem 0.4 s, fork 1.0 s, dot 2.0 s, name 2.8 s
        after `hit`). `logo` is the root note; `logo_style` picks one of five:
        fork   the mark, heard: one warm note, which splits (the way not taken falls a third to the left and fades,
               the way taken bends up a fifth to the right) and lands on a glass note where the dot is
        rails  a train over the joints: two soft double knocks, then a plucked chord
        chime  a platform chime made kind: two glass notes falling, a third lifting, with the echo of a big hall
        swell  no attack at all: one bowed note opens into a wide chord, a few sparks at the dot
        heart  two heartbeats, then one clear bell"""
        out = np.zeros((self.n, 2))
        root, hit = self.s['logo'], self.s['hit']
        left = self.s['dur'] - hit
        f = hz(root)
        style = self.s.get('logo_style', 'fork')

        def sub(at, g=0.05):  # a low octave under where it lands
            t = np.arange(int((left - at) * SR)) / SR
            self.add(out, hit + at, np.sin(2 * np.pi * hz(root - 24) * t) * np.exp(-t * 0.7) * np.minimum(1, t / 0.08) * g)

        def opens(g=0.011):  # the chord opens under the name
            t = np.arange(int((left - 2.8) * SR)) / SR
            e = np.minimum(1, t / 1.2) * np.clip((left - 2.8 - t) / 1.5, 0, 1)
            i0 = int((hit + 2.8) * SR)
            for side, det in ((0, -0.06), (1, 0.06)):
                sig = np.zeros(len(t))
                for m in (root, root + 7, root + 14, root + 16):
                    sig += np.sin(2 * np.pi * hz(m) * 2 ** (det / 12) * t + self.rng.uniform(0, 6))
                seg = (sig * e)[: self.n - i0]
                out[i0:i0 + len(seg), side] += seg * g

        if style == 'fork':
            stem = self.mallet(f, min(left - 0.4, 4.0), 1.5) + 0.5 * self.mallet(f / 2, min(left - 0.4, 4.0), 1.1)
            self.add(out, hit + 0.4, stem * 0.085)
            self.add(out, hit + 1.0, self.glide(f, hz(root - 3), 1.2, 0.42, 3.4) * 0.04, (1.5, 0.5))
            self.add(out, hit + 1.0, self.glide(f, hz(root + 7), min(left - 1.0, 4.5), 0.34, 0.75) * 0.055, (0.55, 1.45))
            dot = self.bell(hz(root + 16), left - 2.0, 1.4)
            t = np.arange(len(dot)) / SR
            dot = dot + 0.28 * self.bell(hz(root + 28), left - 2.0, 0.8) * (0.6 + 0.4 * np.sin(2 * np.pi * 4.2 * t))
            self.add(out, hit + 2.0, dot * 0.06, (0.85, 1.15))
            sub(2.0)
            opens()
        elif style == 'rails':
            for at, m, pan in ((0.4, root - 12, -0.25), (1.0, root - 5, 0.25)):
                for dt, g in ((0.0, 1.0), (0.085, 0.65)):
                    knock = self.mallet(hz(m), 0.6, 9) + 0.4 * self.mallet(hz(m + 12), 0.6, 14)
                    self.add(out, hit + at + dt, knock * 0.085 * g, (1 - pan, 1 + pan))
            for m, dt, g in ((root + 12, 0.0, 1.0), (root + 16, 0.03, 0.8), (root + 19, 0.06, 0.8)):
                self.add(out, hit + 2.0 + dt, self.pluck(hz(m), min(3.0, left - 2.1), True) * 0.07 * g)
            self.add(out, hit + 2.0, self.bell(hz(root + 24), left - 2.0, 1.0) * 0.028, (0.85, 1.15))
            sub(2.0)
            opens()
        elif style == 'chime':
            for at, m, g in ((0.4, root + 16, 0.05), (1.0, root + 12, 0.05), (2.0, root + 19, 0.055), (2.0, root + 24, 0.028)):
                for k, (dt, eg) in enumerate(((0.0, 1.0), (0.3125, 0.3), (0.625, 0.1))):
                    pan = (0, -0.4, 0.4)[k]
                    self.add(out, hit + at + dt, self.bell(hz(m), min(4.0, left - at - dt), 1.0) * g * eg, (1 - pan, 1 + pan))
            self.add(out, hit + 2.0, self.mallet(hz(root - 12), min(3.0, left - 2.0), 1.4) * 0.05)
            sub(2.0, 0.035)
            opens()
        elif style == 'swell':
            for at, m, g in ((0.4, root, 1.0), (1.0, root + 7, 0.8), (1.0, root + 4, 0.7), (1.6, root - 12, 0.8), (1.6, root - 5, 0.6), (1.6, root + 14, 0.5)):
                i0 = int((hit + at) * SR)
                for side, det in ((0, -0.07), (1, 0.07)):
                    seg = self.strings(hz(m) * 2 ** (det / 12), left - at, attack=2.2 - at, release=2.2)[: self.n - i0]
                    out[i0:i0 + len(seg), side] += seg * 0.022 * g
            for at, m, pan in ((2.0, root + 28, -0.3), (2.13, root + 31, 0.35), (2.3, root + 36, 0.0)):
                self.add(out, hit + at, self.bell(hz(m), min(2.5, left - at), 0.8) * 0.02, (1 - pan, 1 + pan))
            sub(2.0, 0.04)
        elif style == 'heart':
            for at, g0 in ((0.4, 1.0), (1.0, 0.85)):
                for dt, g in ((0.0, 1.0), (0.26, 0.65)):
                    t = np.arange(int(0.5 * SR)) / SR
                    thump = np.sin(2 * np.pi * np.cumsum(hz(root - 24) * (1 + 0.9 * np.exp(-t * 30))) / SR) * np.exp(-t * 8)
                    thump += 0.35 * self.mallet(hz(root - 12), 0.5, 12)
                    self.add(out, hit + at + dt, thump * 0.16 * g * g0)
            self.add(out, hit + 2.0, self.bell(hz(root + 19), left - 2.0, 1.2) * 0.06, (0.9, 1.1))
            self.add(out, hit + 2.0, self.mallet(f, min(3.0, left - 2.0), 1.6) * 0.05 + self.mallet(hz(root + 7), min(3.0, left - 2.0), 1.8) * 0.04)
            opens()
        return out

    PENT = (62, 64, 66, 69, 71)  # D major pentatonic: sits over every chord these films use in D

    def fx2(self):
        """The score-born effects: every sound here is notes from the chord under it, no noise. `blooms` (t, gain: a
        low struck octave with a glass glint, for the cuts), `swells` (a, b: the next chord rising into a cut),
        `bends` (a, b: the chord running down in pitch, a train braking), `rides` (t0, b0, b1: rail joints on the
        root, slowing between b0 and b1), `clock` (a, b, interval, gain: tick and tock on two chord notes), `pulse`
        (a, b: a heartbeat on the root), `pings` (a, b, d0, d1: a shower of glass notes, density per 16th), `reports`
        (t, interval, n: voices answering up the scale), `drops` (a, b, rate: rain as high plucks), `doors` (a
        two-note chime), `gliss` (t, length, gain: a run up the scale) and `notify` (the logo's fork and dot, small)."""
        out = np.zeros((self.n, 2))
        s, rng, beat = self.s, np.random.default_rng(21), self.s['beat']
        for at, g in s.get('blooms', []):
            c = self.chord(at)
            f = hz(c[0])
            t = np.arange(int(3.0 * SR)) / SR
            low = np.sin(2 * np.pi * np.cumsum(f * (1 + 0.6 * np.exp(-t * 26))) / SR) * np.exp(-t * 1.5)
            body = self.mallet(f * 2, 3.0, 1.8) + 0.6 * self.mallet(f * 4, 3.0, 2.4) + 0.35 * self.mallet(hz(c[2]), 3.0, 2.6)
            self.add(out, at, (low * 0.9 + body * 0.5) * np.minimum(1, t / 0.003) * 0.16 * g)
            self.add(out, at + 0.02, self.bell(hz(c[3] + 24), 2.5, 1.2) * 0.02 * g, (0.7, 1.3))
        for a, b in s.get('swells', []):
            n = int((b - a) * SR)
            k = np.arange(n) / n
            t = k * (b - a)
            i0 = int(a * SR)
            for side, det in ((0, -0.08), (1, 0.08)):
                sig = np.zeros(n)
                for m in self.chord(b + 0.01)[1:]:
                    w = 2 * np.pi * hz(m + 12) * 2 ** (det / 12) * t + rng.uniform(0, 6)
                    sig += np.sin(w) + k * 0.5 * np.sin(2 * w) + k ** 2 * 0.3 * np.sin(3 * w)
                seg = (sig * k ** 2.5 * np.clip((1 - k) * n / (0.02 * SR), 0, 1))[: self.n - i0]
                out[i0:i0 + len(seg), side] += seg * 0.022
        for a, b in s.get('bends', []):
            n = int((b - a) * SR)
            k = np.arange(n) / n
            fall = 1 - 0.45 * k ** 1.6
            trem = 0.7 + 0.3 * np.sin(2 * np.pi * np.cumsum(28 * (1 - 0.8 * k)) / SR)
            root = self.chord(a)[0]
            sig = np.zeros(n)
            for m, g in ((root + 12, 1.0), (root + 19, 0.6), (root + 36, 0.22), (root + 43, 0.12)):
                ph = 2 * np.pi * np.cumsum(hz(m) * fall) / SR
                sig += g * (np.sin(ph) + 0.3 * np.sin(2 * ph))
            self.add(out, a, sig * trem * np.sin(np.pi * k) ** 0.6 * 0.05)
        for t0, b0, b1 in s.get('rides', []):
            run, T, step, j = b0 - t0, b1 - b0, beat / 2, 0
            while j * step < run + T / 2 - 1e-6:
                d = j * step
                at = t0 + d if d <= run else b0 + T * (1 - np.sqrt(max(0.0, 1 - 2 * (d - run) / T)))
                f = hz(self.chord(at)[0] + 12)
                for dt, g in ((0.0, 1.0), (0.075, 0.6)):
                    self.add(out, at + dt, self.mallet(f, 0.3, 24) * 0.06 * g, (1.15, 0.85) if j % 2 else (0.85, 1.15))
                j += 1
        for a, b, iv, g in s.get('clock', []):
            t0, k = a, 0
            while t0 < b - 0.01:
                c = self.chord(t0)
                self.add(out, t0, self.mallet(hz((c[4] if k % 2 == 0 else c[2]) + 24), 0.25, 38) * 0.035 * g,
                         (1.2, 0.8) if k % 2 == 0 else (0.8, 1.2))
                t0 += iv
                k += 1
        for a, b in s.get('pulse', []):
            t0 = a
            while t0 < b:
                f = hz(self.chord(t0)[0])
                for dt, g in ((0.0, 1.0), (beat / 2, 0.65)):
                    t = np.arange(int(0.45 * SR)) / SR
                    thump = np.sin(2 * np.pi * np.cumsum(f * (1 + 0.8 * np.exp(-t * 30))) / SR) * np.exp(-t * 9)
                    self.add(out, t0 + dt, thump * 0.17 * g * float(ramp(t0, [(a, 0.6), (b, 1.0)])))
                t0 += beat * 2
        for a, b, d0, d1 in s.get('pings', []):
            t0 = a
            while t0 < b:
                for _ in range(rng.poisson(np.interp(t0, [a, b], [d0, d1]))):
                    notes = list(self.chord(t0)[1:]) * 2 + [m - 12 for m in self.PENT]
                    m = notes[rng.integers(len(notes))] + (24, 24, 36)[rng.integers(3)]
                    pan = rng.uniform(0.1, 0.9)
                    self.add(out, t0 + rng.uniform(0, beat / 12), self.bell(hz(m), 0.9, 0.9) * rng.uniform(0.008, 0.02),
                             (2 * (1 - pan), 2 * pan))
                t0 += beat / 4
        for t0, iv, n in s.get('reports', []):
            scale = [m + 12 * o for o in (0, 1) for m in self.PENT if m + 12 * o >= 69][:n]
            for i, m in enumerate(scale):
                pan = 0.25 + 0.5 * i / max(1, n - 1)
                note = self.mallet(hz(m), 1.4, 3.0) + 0.5 * self.bell(hz(m + 12), 1.4, 0.9)
                self.add(out, t0 + i * iv, note * (0.045 + 0.006 * i), (2 * (1 - pan), 2 * pan))
        for a, b, rate in s.get('drops', []):
            for at in np.sort(rng.uniform(a, b, int(rate * (b - a)))):
                m = self.PENT[rng.integers(5)] + (24, 24, 36)[rng.integers(3)]
                pan = rng.uniform(0.05, 0.95)
                self.add(out, at, self.pluck(hz(m), 0.5, True) * rng.uniform(0.012, 0.03), (2 * (1 - pan), 2 * pan))
        for at in s.get('doors', []):
            self.add(out, at, self.bell(hz(78), 1.2, 1.0) * 0.045)
            self.add(out, at + beat / 2, self.bell(hz(74), 1.6, 1.0) * 0.045)
        for at, length, g in s.get('gliss', []):
            scale = [m + 12 * o for o in (-1, 0, 1, 2) for m in self.PENT]
            for i, m in enumerate(scale):
                k = i / (len(scale) - 1)
                self.add(out, at + length * k ** 0.8, self.pluck(hz(m), 1.6, True) * (0.035 + 0.035 * k) * g, (1.4 - 0.8 * k, 0.6 + 0.8 * k))
        for at in s.get('notify', []):
            self.add(out, at, self.glide(hz(74), hz(81), 0.7, 0.14, 4.5) * 0.045, (0.8, 1.2))
            self.add(out, at + 0.22, self.bell(hz(90), 1.3, 1.0) * 0.032, (0.9, 1.1))
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
        mixed += self.fx() * 0.6 + self.reverb(self.fx(), 0.6) * 0.5 + self.reverb(self.fx2(), 0.4)
        dur = self.s['dur']
        mixed *= ramp(self.t, [(0, 0), (0.3 if 'pad' not in self.s else 1.2, 1), (dur - 1.0, 1), (dur, 0)])[:, None]
        mixed = np.tanh(mixed * 2.2)
        return mixed / (np.max(np.abs(mixed)) / 0.89)


def main(name, path):
    score = Score(SPECS[name])
    if name.startswith('logo-'):  # just the logo sound, in the same room as the films, all five at one loudness
        mixed = np.tanh(score.reverb(score.logo()) * 2.2)
        mixed *= ramp(score.t, [(0, 1), (score.s['dur'] - 1.0, 1), (score.s['dur'], 0)])[:, None]
        mixed *= min(0.07 / np.sqrt(np.mean(mixed ** 2)), 0.89 / np.max(np.abs(mixed)))
        pcm = (mixed * 32767).astype(np.int16)
    else:
        pcm = (score.render() * 32767).astype(np.int16)
    with wave.open(path, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
