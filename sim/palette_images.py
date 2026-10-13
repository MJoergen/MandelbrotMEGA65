#!/usr/bin/env python3
"""Renders pictures of a few views with the fire palette (palette 3 in
src/vga/palette_pkg.vhd, using all 9 bits of the count), for the README. The
counts are those of the bit-accurate model (model.py), so the pictures show
what the design calculates.

Usage: palette_images.py [directory]   (default: doc)
Writes <directory>/mandelbrot_<name>.png for each view in VIEWS. The pictures
have half the resolution of the MEGA65 (640x512), to keep the files small."""

import sys
from typing import List
from typing import Tuple

import numpy as np
from numpy.typing import NDArray

import model

# The name, the centre, and the width of the view. The pixels are square, and
# the height follows from the aspect ratio. The smallest width at 640 columns
# is 640 * 2^-16 = 0.0098.
VIEWS: List[Tuple[str, float, float, float]] = [
    ("initial",    -0.3333,    0.0,       2.6667),
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
    for name, centre_x, centre_y, width in VIEWS:
        step = max(1, round(width * 65536 / COLS))
        width_r = step * COLS / 65536.0
        height_r = step * ROWS / 65536.0
        cx, cy = model.view(startx=round((centre_x - width_r / 2) * 65536),
                            starty=round((centre_y - height_r / 2) * 65536),
                            stepx=step, stepy=step, cols=COLS, rows=ROWS)
        cnt = model.hw_count(cx, cy)
        file = f"{directory}/mandelbrot_{name}.png"
        Image.fromarray(fire(cnt)).save(file, optimize=True)
        print(f"{file}: centre {centre_x} {centre_y}, width {width_r:.5f}, "
              f"{(cnt == model.MAX_COUNT).mean() * 100:.1f}% in the set")


if __name__ == "__main__":
    main()
