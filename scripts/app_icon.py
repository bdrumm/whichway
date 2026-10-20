#!/usr/bin/env python3
"""Draw the WhichWay app icon (a track switch: one line splitting into two) and
write it to the iOS asset catalog.

    python3 scripts/app_icon.py            # needs Pillow
"""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
IOS = ROOT / "ios/WhichWay/WhichWay/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

SS = 4  # supersampling factor; geometry below is in 1024-px units
TOP, BOTTOM = (22, 34, 58), (8, 12, 22)
WHITE, BLUE, ORANGE = (245, 247, 250), (46, 124, 255), (255, 122, 26)
LINE = 112
FORK = (512, 590)


def bezier(p0, p1, p2, p3, n=400):
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        yield tuple(u**3 * a + 3 * u * u * t * b + 3 * u * t * t * c + t**3 * d for a, b, c, d in zip(p0, p1, p2, p3))


def segment(p, q, n=300):
    return ((p[0] + (q[0] - p[0]) * i / n, p[1] + (q[1] - p[1]) * i / n) for i in range(n + 1))


def disc(d, c, r, color):
    x, y, r = c[0] * SS, c[1] * SS, r * SS
    d.ellipse((x - r, y - r, x + r, y + r), fill=color)


def stroke(d, points, color):
    for p in points:
        disc(d, p, LINE / 2, color)


def branch(d, x, color):
    # Leave the fork diagonally, bend upright, end at a hollow station dot.
    toward = FORK[0] + (x - FORK[0]) * 0.43
    stroke(d, bezier(FORK, (toward, 520), (x, 450), (x, 340)), color)
    stroke(d, segment((x, 340), (x, 236), 100), color)
    disc(d, (x, 236), 92, color)
    disc(d, (x, 236), 40, TOP)


def draw():
    n = 1024 * SS
    column = Image.new("RGB", (1, n))
    for y in range(n):
        t = y / (n - 1)
        column.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))
    img = column.resize((n, n))
    d = ImageDraw.Draw(img)
    branch(d, 322, BLUE)
    branch(d, 702, ORANGE)
    stroke(d, segment((512, 880), FORK), WHITE)
    disc(d, FORK, 78, WHITE)
    return img.resize((1024, 1024), Image.LANCZOS)


def main():
    draw().save(IOS)


if __name__ == "__main__":
    main()
