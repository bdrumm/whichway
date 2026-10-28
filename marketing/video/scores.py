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
}


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
        kt = np.arange(int(0.45 * SR)) / SR
        ph = 2 * np.pi * np.cumsum(48 + 90 * np.exp(-kt * 30)) / SR
        self.add(out, hit, np.sin(ph) * np.exp(-kt * 7) * 0.2)
        for m, at in self.s['bells']:
            self.add(out, at, self.pluck(hz(m), 3.0, False) * 0.02)
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
