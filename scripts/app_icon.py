#!/usr/bin/env python3
"""Draw the WhichWay app icon and write its light, dark and tinted variants to the iOS asset catalog.

The glyph is the app's own trip thread (a round-capped line with a ring where you start and a filled dot where
you end, as on the Go tab) splitting at a junction: the way to go is solid, the other way fades. The light icon
sits on the accent blue with the Go tab's glow wash from the top-left corner.

    python3 scripts/app_icon.py            # needs Pillow
"""
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

ICONSET = Path(__file__).resolve().parent.parent / "ios/WhichWay/WhichWay/Assets.xcassets/AppIcon.appiconset"

SS = 4  # supersampling factor; geometry below is in 1024-px units
ACCENT = (0, 57, 166)  # AccentColor, light
ACCENT_DARK = (97, 163, 255)  # AccentColor, dark
WHITE = (255, 255, 255)

# The thread on the Go tab: a 6-pt line, 20-pt rings with a 5-pt border; scaled up.
LINE = 92
NODE = 150  # node radius
BORDER = 76
ORIGIN = (512, 762)
FORK = (512, 560)
CHOSEN, OTHER = (712, 236), (312, 236)
FADED = 0.38


def bezier(p0, p1, p2, p3, n=500):
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        yield tuple(u**3 * a + 3 * u * u * t * b + 3 * u * t * t * c + t**3 * d for a, b, c, d in zip(p0, p1, p2, p3))


def segment(p, q, n=300):
    return ((p[0] + (q[0] - p[0]) * i / n, p[1] + (q[1] - p[1]) * i / n) for i in range(n + 1))


def disc(d, c, r, fill):
    x, y, r = c[0] * SS, c[1] * SS, r * SS
    d.ellipse((x - r, y - r, x + r, y + r), fill=fill)


def stroke(d, points):
    for p in points:
        disc(d, p, LINE / 2, 255)


def branch(end):
    # Leave the junction straight up, swing across, and come upright into the end.
    return bezier(FORK, (FORK[0], FORK[1] - 150), (end[0], FORK[1] - 150), end)


def glyph():
    """Coverage masks: (solid, faded)."""
    n = 1024 * SS
    solid, faded = Image.new("L", (n, n), 0), Image.new("L", (n, n), 0)
    s, f = ImageDraw.Draw(solid), ImageDraw.Draw(faded)
    stroke(f, branch(OTHER))
    stroke(s, segment(ORIGIN, FORK))
    stroke(s, branch(CHOSEN))
    disc(s, CHOSEN, NODE - BORDER / 2, 255)  # the end: a filled dot
    disc(s, ORIGIN, NODE, 255)  # the start: a ring, its middle open to the background
    disc(s, ORIGIN, NODE - BORDER, 0)
    disc(f, ORIGIN, NODE, 0)
    return solid, ImageChops.subtract(faded, solid)


def background(base, glow, strength):
    """A flat colour with a radial wash from the top-left corner, as the Go tab's GlowWash."""
    small = 256
    img = Image.new("RGB", (small, small))
    px = img.load()
    for y in range(small):
        for x in range(small):
            t = min(1.0, ((x * x + y * y) ** 0.5) / (small * 1.15))
            w = strength * max(0.0, 1 - t) ** 1.6
            px[x, y] = tuple(round(b + (g - b) * w) for b, g in zip(base, glow))
    return img.resize((1024 * SS, 1024 * SS), Image.BICUBIC)


def compose(bg, color):
    solid, faded = glyph()
    out = bg.copy()
    out.paste(Image.new("RGB", out.size, color), (0, 0), faded.point(lambda v: round(v * FADED)))
    out.paste(Image.new("RGB", out.size, color), (0, 0), solid)
    return out.resize((1024, 1024), Image.LANCZOS)


def tinted():
    """Grayscale glyph on black: the system tints it."""
    solid, faded = glyph()
    out = Image.new("L", solid.size, 0)
    out.paste(255, (0, 0), solid)
    out.paste(round(255 * FADED), (0, 0), faded)
    return out.resize((1024, 1024), Image.LANCZOS).convert("RGB")


def main():
    compose(background(ACCENT, ACCENT_DARK, 0.85), WHITE).save(ICONSET / "AppIcon.png")
    compose(background((10, 14, 24), ACCENT, 0.55), ACCENT_DARK).save(ICONSET / "AppIcon-Dark.png")
    tinted().save(ICONSET / "AppIcon-Tinted.png")


if __name__ == "__main__":
    main()
