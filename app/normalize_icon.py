#!/usr/bin/env python3
"""
Normalize repo-root icon.png to a 1024×1024 square for macOS .icns.

Wide exports (e.g. 16:9) often place the squircle in the center with light
margins. We detect the dark icon body by luminance and crop to a square
region, then scale to 1024.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Optional, Tuple

from PIL import Image


def lum(p: Tuple[int, ...]) -> float:
    r, g, b = p[0], p[1], p[2]
    return 0.299 * r + 0.587 * g + 0.114 * b


def dark_bbox(im: Image.Image, thresh: float) -> Optional[Tuple[int, int, int, int]]:
    w, h = im.size
    pix = im.load()
    min_x, min_y = w, h
    max_x = 0
    max_y = 0
    found = False
    for y in range(h):
        for x in range(w):
            if lum(pix[x, y]) < thresh:
                found = True
                if x < min_x:
                    min_x = x
                if y < min_y:
                    min_y = y
                if x > max_x:
                    max_x = x
                if y > max_y:
                    max_y = y
    if not found:
        return None
    return (min_x, min_y, max_x + 1, max_y + 1)


def square_around(b: tuple[int, int, int, int], w: int, h: int) -> tuple[int, int, int, int]:
    min_x, min_y, max_x, max_y = b
    cw = max_x - min_x
    ch = max_y - min_y
    side = max(cw, ch)
    cx = (min_x + max_x) // 2
    cy = (min_y + max_y) // 2
    left = cx - side // 2
    top = cy - side // 2
    if left < 0:
        left = 0
    if top < 0:
        top = 0
    if left + side > w:
        left = w - side
    if top + side > h:
        top = h - side
    return (left, top, left + side, top + side)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: normalize_icon.py <input.png> <output.png>", file=sys.stderr)
        return 2
    inp = Path(sys.argv[1])
    out = Path(sys.argv[2])
    im = Image.open(inp).convert("RGBA")
    w, h = im.size

    rgb = im.convert("RGB")
    b = dark_bbox(rgb, 140.0)
    if b:
        left, top, right, bottom = square_around(b, w, h)
        sq = im.crop((left, top, right, bottom))
    else:
        side = min(w, h)
        left = (w - side) // 2
        top = (h - side) // 2
        sq = im.crop((left, top, left + side, top + side))

    sq = sq.resize((1024, 1024), Image.Resampling.LANCZOS)
    out.parent.mkdir(parents=True, exist_ok=True)
    sq.save(out, "PNG")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
