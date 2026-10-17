"""Draws Genio's app icon: Wayfarer-style glasses with the gold "genie"
sparkle caught as a reflection in one lens. Rendered at 4x and scaled down
for smooth edges.

Usage: python tools/make_icon.py <output.png> [variant] [size]
variants: a (white frame, dark lenses), b (gold frame on night),
          c (single-lens close-up)"""

import math
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

NIGHT = (22, 17, 64)
DEEP = (12, 9, 38)
VIOLET = (104, 66, 214)
GOLD = (252, 200, 72)
GOLD_LIGHT = (255, 232, 160)
WHITE = (255, 255, 255)


# ---------------------------------------------------------------- geometry

def bezier(p0, p1, p2, p3, n=48):
    pts = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        x = u**3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t**3 * p3[0]
        y = u**3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t**3 * p3[1]
        pts.append((x, y))
    return pts


def wayfarer_lens(x, y, w, h, mirror=False):
    """Outline of a left Wayfarer lens in the box (x, y, w, h): a flat top
    that lifts at the outer corner, a rounded bottom narrowing towards the
    nose. mirror=True gives the right lens."""
    def p(u, v):
        return (x + (w - u * w if mirror else u * w), y + v * h)

    path = []
    path += bezier(p(0.96, 0.10), p(0.70, 0.07), p(0.25, 0.02), p(0.02, -0.02))   # top edge, lifting outward
    path += bezier(p(0.02, -0.02), p(-0.03, 0.30), p(0.02, 0.62), p(0.14, 0.82))  # outer side
    path += bezier(p(0.14, 0.82), p(0.30, 1.04), p(0.62, 1.04), p(0.80, 0.90))    # bottom
    path += bezier(p(0.80, 0.90), p(0.95, 0.76), p(1.00, 0.40), p(0.96, 0.10))    # nose side
    return path


def top_edge(x, y, w, h, mirror=False):
    def p(u, v):
        return (x + (w - u * w if mirror else u * w), y + v * h)
    return bezier(p(0.96, 0.10), p(0.70, 0.07), p(0.25, 0.02), p(0.02, -0.02))


def sparkle_points(cx, cy, r, sharp=2.6, rotation=0.0):
    """Four-pointed star with concave sides (a superellipse, exponent > 1)."""
    pts = []
    for k in range(720):
        a = 2 * math.pi * k / 720
        c, s = math.cos(a), math.sin(a)
        x = math.copysign(abs(c) ** sharp, c) * r
        y = math.copysign(abs(s) ** sharp, s) * r
        xr = x * math.cos(rotation) - y * math.sin(rotation)
        yr = x * math.sin(rotation) + y * math.cos(rotation)
        pts.append((cx + xr, cy + yr))
    return pts


# ---------------------------------------------------------------- painting

def radial_background(s, inner, outer, center=(0.5, 0.45), spread=1.15):
    g = Image.radial_gradient("L").resize((int(s * spread), int(s * spread)), Image.BICUBIC)
    mask = Image.new("L", (s, s), 255)
    mask.paste(g, (int(s * center[0] - g.width / 2), int(s * center[1] - g.height / 2)))
    return Image.composite(Image.new("RGB", (s, s), outer), Image.new("RGB", (s, s), inner), mask)


def vertical_gradient(s, top, bottom):
    g = Image.linear_gradient("L").resize((s, s))
    return Image.composite(Image.new("RGB", (s, s), bottom), Image.new("RGB", (s, s), top), g)


def polygon_mask(s, pts):
    m = Image.new("L", (s, s), 0)
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return m


def glow(base, s, cx, cy, radius, color, strength):
    m = Image.new("L", (s, s), 0)
    ImageDraw.Draw(m).ellipse((cx - radius, cy - radius, cx + radius, cy + radius), fill=255)
    m = m.filter(ImageFilter.GaussianBlur(radius * 0.45)).point(lambda v: int(v * strength))
    return Image.composite(Image.new("RGB", (s, s), color), base, m)


def paint_lens(base, s, lens, sparkle=None, glare=True):
    """Dark tinted glass with a soft glare band and, optionally, the gold
    sparkle reflected in it."""
    mask = polygon_mask(s, lens)
    glass = vertical_gradient(s, DEEP, (52, 36, 128))
    base = Image.composite(glass, base, mask)
    if glare:
        xs = [p[0] for p in lens]
        ys = [p[1] for p in lens]
        x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
        band = Image.new("L", (s, s), 0)
        w = x1 - x0
        ImageDraw.Draw(band).polygon(
            [(x0 + w * 0.10, y1), (x0 + w * 0.32, y1), (x0 + w * 0.62, y0), (x0 + w * 0.40, y0)], fill=70)
        band = ImageChops.multiply(band.filter(ImageFilter.GaussianBlur(s * 0.006)), mask)
        base = Image.composite(Image.new("RGB", (s, s), WHITE), base, band)
    if sparkle:
        cx, cy, r = sparkle
        base = glow(base, s, cx, cy, r * 1.25, GOLD, 0.55)
        d = ImageDraw.Draw(base)
        d.polygon(sparkle_points(cx, cy, r), fill=GOLD)
        d.polygon(sparkle_points(cx, cy, r * 0.42), fill=GOLD_LIGHT)
    return base


def smooth(mask, s, amount=0.004):
    """Blur and re-threshold a mask: thick strokes drawn as many short line
    segments come out with tiny teeth; this rounds them off."""
    return mask.filter(ImageFilter.GaussianBlur(s * amount)).point(lambda v: 255 if v > 127 else 0)


def draw_frame(base, s, lenses, tops, color, t, bridge_y, cx):
    m = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(m)
    for lens in lenses:
        d.line(lens + [lens[0]], fill=255, width=int(t), joint="curve")
    # Wayfarer brow: the top bar is heavier than the rest of the rim.
    for top in tops:
        lifted = [(x, y - t * 0.35) for x, y in top]
        d.line(lifted, fill=255, width=int(t * 1.7), joint="curve")
        for x, y in (lifted[0], lifted[-1]):
            r = t * 0.85
            d.ellipse((x - r, y - r, x + r, y + r), fill=255)
    # Bridge between the lenses.
    l_in, r_in = tops[0][0], tops[1][0]
    d.line(bezier((l_in[0], l_in[1] - t * 0.3), (cx - t, bridge_y), (cx + t, bridge_y), (r_in[0], r_in[1] - t * 0.3)),
           fill=255, width=int(t * 1.1), joint="curve")
    m = smooth(m, s)
    # A faint shadow under the frame lifts it off the background.
    shadow = m.filter(ImageFilter.GaussianBlur(s * 0.01)).point(lambda v: int(v * 0.35))
    shadow = ImageChops.offset(shadow, 0, int(s * 0.008))
    base = Image.composite(Image.new("RGB", (s, s), DEEP), base, shadow)
    return Image.composite(Image.new("RGB", (s, s), color), base, m)


# ---------------------------------------------------------------- variants

def glasses_layout(s, scale=1.06, cy=0.515):
    w, h = s * 0.355 * scale, s * 0.25 * scale
    gap = s * 0.07 * scale
    y = s * cy - h / 2
    left_x = s / 2 - gap / 2 - w
    right_x = s / 2 + gap / 2
    lenses = [wayfarer_lens(left_x, y, w, h), wayfarer_lens(right_x, y, w, h, mirror=True)]
    tops = [top_edge(left_x, y, w, h), top_edge(right_x, y, w, h, mirror=True)]
    return lenses, tops, (right_x, y, w, h)


def glasses_icon(s, background, frame, sparkle_scale=1.0, sparkle_at=(0.36, 0.38)):
    base = background
    lenses, tops, (rx, ry, rw, rh) = glasses_layout(s)
    base = paint_lens(base, s, lenses[0])
    base = paint_lens(base, s, lenses[1])
    cx, cy, r = rx + rw * sparkle_at[0], ry + rh * sparkle_at[1], s * 0.095 * sparkle_scale
    # The glow goes under the frame, so the rim stays its own colour...
    base = glow(base, s, cx, cy, r * 1.3, GOLD, 0.6)
    base = draw_frame(base, s, lenses, tops, frame, s * 0.036, ry - s * 0.014, s / 2)
    # ...and the sparkle on top of it, so a big one can break out of the lens.
    d = ImageDraw.Draw(base)
    d.polygon(sparkle_points(cx, cy, r), fill=GOLD)
    d.polygon(sparkle_points(cx, cy, r * 0.42), fill=GOLD_LIGHT)
    return base


def variant_a(s):
    return glasses_icon(s, radial_background(s, (90, 60, 200), NIGHT, center=(0.5, 0.42), spread=1.6), WHITE)


def variant_b(s):
    return glasses_icon(s, radial_background(s, (56, 38, 140), DEEP, center=(0.5, 0.42), spread=1.6), GOLD)


def variant_c(s):
    return glasses_icon(s, radial_background(s, (90, 60, 200), NIGHT, center=(0.5, 0.42), spread=1.6), WHITE,
                        sparkle_scale=1.7, sparkle_at=(0.62, 0.05))


VARIANTS = {"a": variant_a, "b": variant_b, "c": variant_c}


def main(out, variant="a", size=1024):
    s = size * 4
    img = VARIANTS[variant](s)
    img.resize((size, size), Image.LANCZOS).save(out, "PNG")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "a", int(sys.argv[3]) if len(sys.argv) > 3 else 1024)
