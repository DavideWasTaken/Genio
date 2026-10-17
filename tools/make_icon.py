"""Draws Genio's app icon: white glasses on a night-to-violet gradient, with
the gold sparkle of the "genie". Rendered at 4x and scaled down for smooth
edges. Usage: python tools/make_icon.py <output.png> [size]"""

import math
import sys

from PIL import Image, ImageDraw, ImageFilter

NIGHT = (30, 25, 82)
VIOLET = (107, 64, 209)
GLOW = (160, 120, 255)
GOLD = (250, 199, 69)
WHITE = (255, 255, 255)


def gradient(size: int) -> Image.Image:
    """Diagonal night -> violet gradient."""
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            px[x, y] = tuple(int(NIGHT[i] + (VIOLET[i] - NIGHT[i]) * t) for i in range(3))
    return img


def sparkle(draw: ImageDraw.ImageDraw, cx: float, cy: float, r: float, fill) -> None:
    """Four-pointed star with concave sides and sharp tips (a superellipse
    with exponent > 1 pinches the sides inwards)."""
    points = []
    for k in range(720):
        a = 2 * math.pi * k / 720
        c, s_ = math.cos(a), math.sin(a)
        x = math.copysign(abs(c) ** 2.4, c)
        y = math.copysign(abs(s_) ** 2.4, s_)
        points.append((cx + r * x, cy + r * y))
    draw.polygon(points, fill=fill)


def main(out: str, size: int = 1024) -> None:
    s = size * 4
    base = gradient(256).resize((s, s), Image.BICUBIC)

    # Soft glow behind the glasses.
    glow = Image.new("L", (s, s), 0)
    ImageDraw.Draw(glow).ellipse((s * 0.12, s * 0.30, s * 0.88, s * 0.86), fill=150)
    glow = glow.filter(ImageFilter.GaussianBlur(s * 0.09))
    base = Image.composite(Image.new("RGB", (s, s), GLOW), base, glow.point(lambda v: int(v * 0.55)))

    draw = ImageDraw.Draw(base)
    stroke = int(s * 0.05)
    cy = s * 0.61
    lens_w, lens_h = s * 0.27, s * 0.235
    gap = s * 0.07
    left = (s / 2 - gap / 2 - lens_w, cy - lens_h / 2, s / 2 - gap / 2, cy + lens_h / 2)
    right = (s / 2 + gap / 2, cy - lens_h / 2, s / 2 + gap / 2 + lens_w, cy + lens_h / 2)
    for box in (left, right):
        draw.rounded_rectangle(box, radius=s * 0.085, outline=WHITE, width=stroke)
    # Wayfarer brow: one thick bar across the top of both lenses.
    brow_h = stroke * 1.15
    draw.rounded_rectangle(
        (left[0] - stroke * 0.3, left[1] - stroke * 0.2, right[2] + stroke * 0.3, left[1] + brow_h),
        radius=brow_h / 2, fill=WHITE)

    # The genie's sparkle, with a warm halo, over the right lens.
    halo = Image.new("L", (s, s), 0)
    hx, hy = s * 0.70, s * 0.27
    ImageDraw.Draw(halo).ellipse((hx - s * 0.13, hy - s * 0.13, hx + s * 0.13, hy + s * 0.13), fill=190)
    halo = halo.filter(ImageFilter.GaussianBlur(s * 0.05))
    base = Image.composite(Image.new("RGB", (s, s), GOLD), base, halo.point(lambda v: int(v * 0.45)))
    draw = ImageDraw.Draw(base)
    sparkle(draw, hx, hy, s * 0.13, GOLD)
    sparkle(draw, s * 0.84, s * 0.15, s * 0.045, GOLD)
    sparkle(draw, s * 0.55, s * 0.17, s * 0.032, (255, 230, 160))

    base.resize((size, size), Image.LANCZOS).save(out, "PNG")


if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 1024)
