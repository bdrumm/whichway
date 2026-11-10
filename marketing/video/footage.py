#!/usr/bin/env python3
"""Fetch the real footage for the live-action cut and unpack each shot into JPEG frames the film page can draw.

The clips are free stock video from Mixkit (mixkit.co, Mixkit Stock Video Free License: free for commercial use, no
attribution, not to be redistributed as stock), so they are downloaded here by id and never committed.

    python3 footage.py            # downloads to footage/raw, writes footage/<shot>/0001.jpg ... at 30 fps, 1920x1080
                                  # and footage/track.js (needs opencv-python-headless and numpy)
"""
import os
import subprocess
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'footage')
# shot: (mixkit id, start in the clip, seconds of film, playback speed, extra filter)
SHOTS = {
    'arrive':   (1622, 0.5, 5.2, 1.0, ''),        # a train's headlights coming into the station
    'bokeh':    (4330, 2.0, 9.0, 1.0, ''),        # the city at night, out of focus
    'bokeh2':   (4330, 20.0, 8.0, 1.0, ''),
    'pass':     (40672, 0.0, 2.7, 1.5, ''),       # a train running past, windows lit
    'skyline':  (4334, 0.0, 6.5, 1.0, ''),
    'album':    (21449, 0.5, 4.0, 1.0, ''),       # a man with a photo album
    'remember': (21449, 6.6, 1.5, 1.0, ''),
    'clock86':  (4180, 2.0, 5.2, 0.5, ''),        # the clock in the concourse
    'tunnel86': (27423, 2.0, 12.0, 1.0, ''),      # a tunnel from the cab, time-remapped by the film
    'hands':    (28893, 0.0, 1.5, 4.0, ''),       # clock hands sweeping
    'young':    (46615, 10.6, 5.2, 0.6, ''),      # a young couple, backlit
    'rider':    (22504, 13.0, 4.0, 1.0, 'crop=iw*0.8:ih*0.8:0:ih*0.12,'),
    'tunnel':   (44882, 4.0, 22.0, 1.0, ''),      # a tunnel at speed, time-remapped by the film
    'board':    (1623, 0.8, 5.2, 1.0, ''),        # stepping across the platform onto a train
    'nyc':      (4431, 0.2, 1.5, 1.0, ''),
    'wagon':    (4333, 4.3, 1.5, 1.0, ''),
    'hall':     (4181, 2.0, 2.7, 1.0, ''),
    'clock':    (4180, 5.2, 4.0, 1.0, ''),
    'couple':   (5902, 3.2, 5.2, 1.0, ''),        # an older couple, arm in arm
    'sunset':   (22510, 11.0, 4.0, 1.0, ''),
}


def fetch(clip):
    raw = os.path.join(OUT, 'raw')
    os.makedirs(raw, exist_ok=True)
    path = os.path.join(raw, f'{clip}.mp4')
    if os.path.exists(path) and os.path.getsize(path) > 100000:
        return path
    for res in (1080, 720):
        try:
            req = urllib.request.Request(f'https://assets.mixkit.co/videos/{clip}/{clip}-{res}.mp4', headers={'User-Agent': 'Mozilla/5.0'})
            with urllib.request.urlopen(req, timeout=180) as r, open(path, 'wb') as f:
                f.write(r.read())
            return path
        except Exception as e:  # fall back to the smaller file
            print(f'{clip}-{res}: {e}', file=sys.stderr)
    raise SystemExit(f'could not fetch clip {clip}')


def unpack(name):
    clip, start, seconds, speed, extra = SHOTS[name]
    src = fetch(clip)
    d = os.path.join(OUT, name)
    os.makedirs(d, exist_ok=True)
    vf = (f'{extra}setpts=PTS/{speed},fps=30,scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080')
    subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-ss', str(start), '-t', str(seconds * speed + 0.5), '-i', src, '-vf', vf,
                    '-frames:v', str(round(seconds * 30)), '-q:v', '4', os.path.join(d, '%04d.jpg')], check=True)
    print(name, len(os.listdir(d)))


# The clock's face is repainted by the film to the hour the story needs, so it has to be followed through the shot:
# its centre and radius in one reference frame of the clip, carried to every frame by matching the building around it.
CLOCK_REF = (4180, 4.0, (1245.0, 158.0, 67.0))


def track_clock(names=('clock86', 'clock')):
    import json
    import cv2
    import numpy as np
    clip, at, (cx, cy, r) = CLOCK_REF
    ref_path = os.path.join(OUT, 'clock_ref.jpg')
    subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-ss', str(at), '-i', fetch(clip), '-frames:v', '1', '-vf',
                    'scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080', '-q:v', '2', ref_path], check=True)
    orb = cv2.ORB_create(4000)
    ref = cv2.imread(ref_path, cv2.IMREAD_GRAYSCALE)
    kr, dr = orb.detectAndCompute(ref, None)
    bf = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True)
    out = {}
    for name in names:
        d, rows, last = os.path.join(OUT, name), [], None
        for f in sorted(os.listdir(d)):
            k, des = orb.detectAndCompute(cv2.imread(os.path.join(d, f), cv2.IMREAD_GRAYSCALE), None)
            m = bf.match(dr, des)
            src = np.float32([kr[x.queryIdx].pt for x in m]); dst = np.float32([k[x.trainIdx].pt for x in m])
            M, inl = cv2.estimateAffinePartial2D(src, dst, method=cv2.RANSAC, ransacReprojThreshold=3)
            if M is not None and inl.sum() > 30:
                s = float(np.hypot(M[0, 0], M[1, 0]))
                last = [float(M[0, 0] * cx + M[0, 1] * cy + M[0, 2]), float(M[1, 0] * cx + M[1, 1] * cy + M[1, 2]), r * s]
            rows.append(last)
        first = next(x for x in rows if x)
        rows = [x or first for x in rows]
        # smooth the track, so the painted face does not shimmer against the picture
        a = np.array(rows); k = np.ones(7) / 7
        sm = np.stack([np.convolve(np.pad(a[:, i], 3, mode='edge'), k, mode='valid') for i in range(3)], axis=1)
        out[name] = [[round(float(v), 2) for v in row] for row in sm]
        print(name, 'tracked', len(rows), out[name][0], out[name][-1])
    with open(os.path.join(OUT, 'track.js'), 'w') as f:
        f.write('// written by footage.py: the clock face [x, y, radius] per frame of each shot\nconst TRACK = ' + json.dumps(out) + ';\n')


if __name__ == '__main__':
    for n in (sys.argv[1:] or SHOTS):
        unpack(n)
    track_clock()
