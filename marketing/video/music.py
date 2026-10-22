#!/usr/bin/env python3
"""Synthesise the film's score (62 s, 120 bpm, Bm - G - D - A) and write it as a WAV.

    python3 music.py out.wav            # needs numpy

A pad from the first frame, a plucked arpeggio when the phone appears (12 s), a pulse and bass when the ride
starts (24 s), the full band for the insights (42 s), a riser into the logo hit at 54.6 s, and a long ring-out.
"""
import sys
import wave

import numpy as np

SR = 44100
DUR = 62.0
N = int(SR * DUR)
BEAT = 0.5
HIT = 54.6

CHORDS = [  # midi notes, one chord per 4 s
    [47, 54, 59, 62, 66],  # Bm
    [43, 50, 55, 59, 62],  # G
    [50, 57, 62, 66, 69],  # D
    [45, 52, 57, 61, 64],  # A
]


def hz(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def chord_at(t):
    return CHORDS[int(t // 4) % 4]


def env_lin(t, pts):
    """Piecewise-linear automation over time array t."""
    xs, ys = zip(*pts)
    return np.interp(t, xs, ys)


T = np.arange(N) / SR
rng = np.random.default_rng(5)


def lowpass(x, cutoff):
    a = np.exp(-2 * np.pi * cutoff / SR)
    y = np.empty_like(x)
    acc = 0.0
    for i in range(len(x)):  # small: only used on short buffers
        acc = (1 - a) * x[i] + a * acc
        y[i] = acc
    return y


def pad():
    out = np.zeros((N, 2))
    for c in range(16):  # chord slots
        t0 = c * 4.0
        if t0 >= HIT:
            break
        notes = chord_at(t0)
        length = min(4.6, HIT - t0 + 0.4)
        n = int(length * SR)
        t = np.arange(n) / SR
        e = np.minimum(1, t / 1.2) * np.clip((length - t) / 0.8, 0, 1)
        for side, det in ((0, -0.07), (1, 0.07)):
            sig = np.zeros(n)
            for m in notes[1:]:
                f = hz(m) * 2 ** (det / 12)
                for h, amp in ((1, 1.0), (2, 0.35), (3, 0.15), (4, 0.06)):
                    sig += amp * np.sin(2 * np.pi * f * h * t + rng.uniform(0, 6))
            i0 = int(t0 * SR)
            out[i0:i0 + n, side] += (sig * e)[: N - i0]
    out *= 0.018
    return out


def pluck(f, length=0.9):
    n = int(length * SR)
    t = np.arange(n) / SR
    s = np.sin(2 * np.pi * f * t) + 0.3 * np.sin(4 * np.pi * f * t) + 0.08 * np.sin(6 * np.pi * f * t)
    return s * np.exp(-t * 6) * np.minimum(1, t / 0.004)


def arp():
    out = np.zeros((N, 2))
    step = BEAT / 2
    k = 0
    t = 12.0
    pattern = [0, 2, 3, 4, 3, 2, 4, 1]
    while t < HIT - 0.1:
        notes = chord_at(t)
        m = notes[pattern[k % 8]] + 12
        p = pluck(hz(m))
        vel = env_lin(t, [(12, 0.35), (24, 0.6), (42, 0.85), (52, 1.0)]) * (1.0 if k % 2 == 0 else 0.7)
        pan = 0.5 + 0.35 * np.sin(k * 0.9)
        i0 = int(t * SR)
        seg = p[: N - i0] * vel
        out[i0:i0 + len(seg), 0] += seg * (1 - pan)
        out[i0:i0 + len(seg), 1] += seg * pan
        t += step
        k += 1
    return out * 0.06


def kick(vel):
    n = int(0.45 * SR)
    t = np.arange(n) / SR
    f = 48 + 90 * np.exp(-t * 30)
    ph = 2 * np.pi * np.cumsum(f) / SR
    return np.sin(ph) * np.exp(-t * 7) * vel


def drums():
    out = np.zeros(N)
    t = 24.0
    while t < HIT - 0.3:
        vel = env_lin(t, [(24, 0.45), (35, 0.6), (42, 0.9), (54, 1.0)])
        i0 = int(t * SR)
        k = kick(vel)
        out[i0:i0 + len(k)] += k[: N - i0]
        # off-beat hat from 42 s
        if t >= 42:
            j0 = int((t + BEAT / 2) * SR)
            hn = int(0.06 * SR)
            hat = np.diff(rng.standard_normal(hn + 1)) * np.exp(-np.arange(hn) / SR * 60) * 0.07 * vel
            out[j0:j0 + hn] += hat[: max(0, N - j0)]
        t += BEAT
    return np.stack([out, out], axis=1) * 0.32


def bass():
    out = np.zeros(N)
    for c in range(6, 14):
        t0 = c * 4.0
        if t0 >= HIT:
            break
        f = hz(chord_at(t0)[0] - 12)
        n = int(min(4.0, HIT - t0) * SR)
        t = np.arange(n) / SR
        # eighth-note pulse, ducked by the kick
        pulse = 0.55 + 0.45 * np.abs(np.sin(np.pi * t / (BEAT / 2)))
        s = np.tanh(1.6 * np.sin(2 * np.pi * f * t)) * pulse * np.minimum(1, t / 0.05) * np.clip((n / SR - t) / 0.05, 0, 1)
        i0 = int(t0 * SR)
        out[i0:i0 + n] += s
    vol = env_lin(T, [(24, 0.6), (42, 1.0), (54, 1.0)])
    return np.stack([out * vol] * 2, axis=1) * 0.07


def riser():
    a, b = HIT - 2.4, HIT
    n = int((b - a) * SR)
    t = np.arange(n) / SR
    noise = rng.standard_normal(n)
    # brighten as it rises: mix of raw and smoothed noise
    sm = np.convolve(noise, np.ones(24) / 24, mode='same')
    k = t / (b - a)
    s = (sm * (1 - k) + noise * k * 0.15) * k ** 2
    out = np.zeros((N, 2))
    i0 = int(a * SR)
    out[i0:i0 + n, 0] = s
    out[i0:i0 + n, 1] = np.roll(s, 40)
    return out * 0.05


def final_hit():
    notes = [38, 50, 57, 62, 66, 69, 74, 78]  # D major, wide
    length = DUR - HIT
    n = int(length * SR)
    t = np.arange(n) / SR
    out = np.zeros((N, 2))
    e = np.exp(-t * 0.45) * np.minimum(1, t / 0.01) * np.clip((length - t) / 1.2, 0, 1)
    for side, det in ((0, -0.05), (1, 0.05)):
        sig = np.zeros(n)
        for i, m in enumerate(notes):
            f = hz(m) * 2 ** (det / 12)
            amp = 1.4 if i == 0 else 1.0
            for h, a in ((1, 1.0), (2, 0.3), (3, 0.12)):
                sig += amp * a * np.sin(2 * np.pi * f * h * t + rng.uniform(0, 6))
        i0 = int(HIT * SR)
        out[i0:i0 + n, side] = sig * e
    k = kick(1.3)
    i0 = int(HIT * SR)
    out[i0:i0 + len(k)] += np.stack([k, k], axis=1) * 4.0
    # a high bell on the dot landing (56.6 s)
    for m, at in ((86, 56.7), (93, 57.4)):
        p = pluck(hz(m), 3.0)
        j = int(at * SR)
        out[j:j + len(p)] += np.stack([p, p], axis=1) * 0.25
    return out * 0.085


def reverb(x, mix=0.3):
    """Schroeder: parallel feedback combs, then allpasses, per channel."""
    out = np.zeros_like(x)
    for ch in range(2):
        s = x[:, ch]
        acc = np.zeros(N)
        for d_ms, g in ((29.7, 0.78), (37.1, 0.77), (41.1, 0.76), (43.7, 0.75)):
            d = int(d_ms * SR / 1000) + ch * 23
            y = s.copy()
            # block recursion: y[n] = s[n] + g*y[n-d], computed d samples at a time
            for i in range(d, N, d):
                j = min(i + d, N)
                y[i:j] += g * y[i - d:j - d]
            acc += y
        for d_ms, g in ((5.0, 0.7), (1.7, 0.7)):
            d = int(d_ms * SR / 1000)
            y = np.zeros(N)
            buf = acc
            for i in range(0, N, d):
                j = min(i + d, N)
                prev_in = buf[i - d:j - d] if i >= d else np.zeros(j - i)
                prev_out = y[i - d:j - d] if i >= d else np.zeros(j - i)
                y[i:j] = -g * buf[i:j] + prev_in + g * prev_out
            acc = y
        out[:, ch] = acc * 0.25
    return x * (1 - mix) + out * mix


def main(path):
    wet = pad() + arp() + final_hit()
    mixed = reverb(wet, 0.35) + drums() + bass() + riser()
    # master: fade in, fade out, soft clip, normalise
    master = env_lin(T, [(0, 0), (1.5, 1), (DUR - 1.0, 1), (DUR, 0)])
    mixed *= master[:, None]
    mixed = np.tanh(mixed * 1.4)
    mixed /= np.max(np.abs(mixed)) / 0.89
    pcm = (mixed * 32767).astype(np.int16)
    with wave.open(path, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


if __name__ == '__main__':
    main(sys.argv[1])
