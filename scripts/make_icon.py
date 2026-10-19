#!/usr/bin/env python3
"""Draws the Disk Atlas app icon (brand mark on a dark green tile) and writes an .icns file.
Usage: python3 scripts/make_icon.py <output.icns>   (needs PIL and macOS `iconutil`)"""
import math
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

TILE = "#293e32"
SQUARES = ["#e9efe9", "#b6c8ba", "#b9afd8", "#ddc6b6"]  # same hues as .brand-mark i in app.css (first one lightened for contrast)
SIZE = 1024


def draw_master() -> Image.Image:
    scale = 2  # supersample for smooth edges
    s = SIZE * scale
    image = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(image)
    margin = int(s * 0.098)  # macOS icon grid: tile fills ~80% of the canvas
    d.rounded_rectangle([margin, margin, s - margin, s - margin], radius=int(s * 0.18), fill=TILE)
    mark = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    m = ImageDraw.Draw(mark)
    cell, gap = int(s * 0.19), int(s * 0.045)
    start = (s - (2 * cell + gap)) // 2
    for index, color in enumerate(SQUARES):
        x = start + (index % 2) * (cell + gap)
        y = start + (index // 2) * (cell + gap)
        m.rounded_rectangle([x, y, x + cell, y + cell], radius=int(cell * 0.28), fill=color)
    mark = mark.rotate(6, resample=Image.BICUBIC, center=(s // 2, s // 2))  # -6° like the in-app mark (PIL rotates counter-clockwise)
    image.alpha_composite(mark)
    return image.resize((SIZE, SIZE), Image.LANCZOS)


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    output = Path(sys.argv[1])
    master = draw_master()
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for base in (16, 32, 128, 256, 512):
            master.resize((base, base), Image.LANCZOS).save(iconset / f"icon_{base}x{base}.png")
            master.resize((base * 2, base * 2), Image.LANCZOS).save(iconset / f"icon_{base}x{base}@2x.png")
        output.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(output)], check=True)


if __name__ == "__main__":
    main()
