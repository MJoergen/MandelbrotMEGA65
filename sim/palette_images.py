#!/usr/bin/env python3
"""Renders pictures for the README, using the palettes of
src/vga/palette_pkg.vhd (all 9 bits of the count, except in palette 1). The
counts are those of the bit-accurate model (model.py), so the pictures show
what the design calculates.

Usage: palette_images.py [directory]   (default: doc)
Writes <directory>/mandelbrot_palette<n>.png, the initial view in each of the
four palettes, and <directory>/mandelbrot_<name>.png for each view in VIEWS, in
the fire palette (palette 3). The pictures have half the resolution of the
MEGA65 (640x512), to keep the files small."""

import sys
from typing import List
from typing import Tuple

import numpy as np
from numpy.typing import NDArray

import model

# The name, the centre, and the width of the view. The pixels are square, and
# the height follows from the aspect ratio. The smallest width at 640 columns
# is 640 * 2^-16 = 0.0098.
INITIAL = (-0.3333, 0.0, 2.6667)
VIEWS: List[Tuple[str, float, float, float]] = [
    ("seahorse",   -0.7430,    0.1127,    0.03),
    ("elephant",    0.275,     0.0,       0.12),
    ("spiral",     -0.7269,    0.1889,    0.04),
    ("minibrot",   -1.7549,    0.0,       0.04),
]

COLS = 640
ROWS = 512


def to_332(r: NDArray[np.float64], g: NDArray[np.float64],
           b: NDArray[np.float64]) -> NDArray[np.uint8]:
    """RRRGGGBB, rounded to the nearest level, expanded to 8 bits per colour
    by repeating the bits, as the MEGA65 does."""
    r_v = np.floor(r * 7.0 + 0.5).astype(np.int64)
    g_v = np.floor(g * 7.0 + 0.5).astype(np.int64)
    b_v = np.floor(b * 3.0 + 0.5).astype(np.int64)
    return np.stack([r_v * 255 // 7, g_v * 255 // 7, b_v * 255 // 3],
                    -1).astype(np.uint8)


def count(cnt: NDArray[np.int64]) -> NDArray[np.uint8]:
    """Palette 1, the lower 8 bits of the count are RRRGGGBB. The set is
    white."""
    v = cnt & 0xFF
    rgb = np.stack([((v >> 5) & 7) * 255 // 7, ((v >> 2) & 7) * 255 // 7,
                    (v & 3) * 255 // 3], -1).astype(np.uint8)
    rgb[cnt == model.MAX_COUNT] = 255
    return rgb


def rainbow(cnt: NDArray[np.int64]) -> NDArray[np.uint8]:
    """Palette 2, see make_rainbow in palette_pkg.vhd. The set is black."""
    h = (cnt % 16) / 16.0 * 6.0
    k = np.floor(h).astype(np.int64)
    f = h - np.floor(h)
    one, zero = np.ones_like(f), np.zeros_like(f)
    r = np.choose(k, [one, 1.0 - f, zero, zero, f, one])
    g = np.choose(k, [f, one, one, 1.0 - f, zero, zero])
    b = np.choose(k, [zero, zero, f, one, one, 1.0 - f])
    rgb = to_332(r, g, b)
    rgb[cnt == model.MAX_COUNT] = 0
    return rgb


def blue_orange(cnt: NDArray[np.int64]) -> NDArray[np.uint8]:
    """Palette 4, see make_blue_orange in palette_pkg.vhd. The set is
    black."""
    stops = np.array([0.0, 0.16, 0.42, 0.64, 0.86, 1.0])
    red = np.array([0.0, 0.13, 0.93, 1.0, 0.0, 0.0])
    green = np.array([0.03, 0.42, 1.0, 0.67, 0.01, 0.03])
    blue = np.array([0.4, 0.8, 1.0, 0.0, 0.0, 0.4])
    x = np.log2(cnt.astype(np.float64) + 1.0) / 3.0
    t = x - np.floor(x)
    rgb = to_332(np.interp(t, stops, red), np.interp(t, stops, green),
                 np.interp(t, stops, blue))
    rgb[cnt == model.MAX_COUNT] = 0
    return rgb


def fire(cnt: NDArray[np.int64]) -> NDArray[np.uint8]:
    """Palette 3 (fire), see make_fire in palette_pkg.vhd. The set is black."""
    x = np.sqrt(cnt.astype(np.float64)) / 8.0
    t = x - np.floor(x)
    rgb = to_332(np.clip(3.0 * t, 0, 1), np.clip(3.0 * t - 1.0, 0, 1),
                 np.clip(3.0 * t - 2.0, 0, 1))
    rgb[cnt == model.MAX_COUNT] = 0
    return rgb


def main() -> None:
    from PIL import Image
    directory = sys.argv[1] if len(sys.argv) > 1 else "doc"
    palettes = [count, rainbow, fire, blue_orange]
    for name, centre_x, centre_y, width in [("initial",) + INITIAL] + VIEWS:
        step = max(1, round(width * 65536 / COLS))
        width_r = step * COLS / 65536.0
        height_r = step * ROWS / 65536.0
        cx, cy = model.view(startx=round((centre_x - width_r / 2) * 65536),
                            starty=round((centre_y - height_r / 2) * 65536),
                            stepx=step, stepy=step, cols=COLS, rows=ROWS)
        cnt = model.hw_count(cx, cy)
        if name == "initial":
            for n, palette in enumerate(palettes, 1):
                file = f"{directory}/mandelbrot_palette{n}.png"
                Image.fromarray(palette(cnt)).save(file, optimize=True)
                print(file)
            continue
        file = f"{directory}/mandelbrot_{name}.png"
        Image.fromarray(fire(cnt)).save(file, optimize=True)
        print(f"{file}: centre {centre_x} {centre_y}, width {width_r:.5f}, "
              f"{(cnt == model.MAX_COUNT).mean() * 100:.1f}% in the set")


if __name__ == "__main__":
    main()
