#!/usr/bin/env python3
"""Usage: scripts/icon/fix_icon.py <in.icns> <out.icns>

The original icon was a blue squircle on an opaque dark square. macOS icons need a transparent
margin: remove the dark backdrop (un-premultiplying the anti-aliased edge so no dark fringe
remains) and fit the squircle to Apple's 824/1024 grid.
"""
import subprocess, sys, tempfile
from pathlib import Path
import numpy as np
from PIL import Image

src, dst = Path(sys.argv[1]), Path(sys.argv[2])
tmp = Path(tempfile.mkdtemp())
subprocess.run(["iconutil", "-c", "iconset", str(src), "-o", str(tmp / "in.iconset")], check=True)
im = np.asarray(Image.open(tmp / "in.iconset/icon_512x512@2x.png").convert("RGB")).astype(np.float64)
bg = im[4, 4].copy()
# Alpha from distance to the backdrop colour: within 8 levels is backdrop noise (transparent),
# 60 levels away counts as fully squircle.
dist = np.sqrt(((im - bg) ** 2).sum(-1))
a = np.clip((dist - 8) / 52.0, 0, 1)
rgb = np.where(a[..., None] > 0, (im - (1 - a[..., None]) * bg) / np.maximum(a[..., None], 1e-6), 0)
rgba = np.dstack([np.clip(rgb, 0, 255), a * 255]).astype(np.uint8)
img = Image.fromarray(rgba, "RGBA")
ys, xs = np.nonzero(a > 0.5)
img = img.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))
canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
canvas.paste(img.resize((824, 824), Image.LANCZOS), (100, 100))
out = tmp / "out.iconset"; out.mkdir()
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        px = size * scale
        name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
        canvas.resize((px, px), Image.LANCZOS).save(out / name)
subprocess.run(["iconutil", "-c", "icns", str(out), "-o", str(dst)], check=True)
print(dst, "squircle bbox", xs.min(), ys.min(), xs.max(), ys.max())
