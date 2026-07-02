#!/usr/bin/env python3
"""Stitch a live-filter GIF of the REAL order box: type a query, watch the list narrow.

    python make_filter_gif.py [out.gif]

render_gif freezes the page timeline, so (like the dialogue typewriter) we render each
keystroke state statically and encode with ffmpeg. ONE harness run emits all
palette_type_* blocks (test_palette_typing.lua); we build_view + element-screenshot the
#cv canvas for each, crop to a FIXED rect (the panel is one size while the list filters
within it), hold the ends, and two-pass palette encode.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

from PIL import Image
from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.dirname(HERE)
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "shots", "palette_filter.gif")
FPS = 18
ROOTS = [os.path.join(KIT, "..", d) for d in ("sauce-shortorder", "SauceCanonical", "PZ-TooltipLib", "SauceTooltips")]

# 1. one harness run -> all palette_type_* JSON blocks, in order
# Run pztest from git-bash into out/_harness.txt FIRST (Python's `bash` resolves to a
# broken WSL stub):  bash ../pztest > out/_harness.txt 2>/dev/null
with open(os.path.join(HERE, "out", "_harness.txt"), "r", encoding="utf-8", errors="replace") as fh:
    raw = fh.read().replace("\r", "")
blocks = {}
for m in re.finditer(r"@@UIVIEW_BEGIN:(palette_type_\d+)@@\n(.*?)@@UIVIEW_END:\1@@", raw, re.S):
    blocks[m.group(1)] = m.group(2)
names = sorted(blocks)
assert names, "no palette_type_* blocks emitted (is test_palette_typing.lua present?)"

# fixed crop = the full zero-state panel (bbox of its rect ops), reused for every frame
f0 = json.loads(blocks[names[0]])
boxed = [o for o in f0["ops"] if "w" in o and "h" in o]
X0, X1 = 216, 974
Y0 = max(0, int(min(o["y"] for o in boxed)) - 3)
Y1 = int(max(o["y"] + o["h"] for o in boxed)) + 3


def shot(pg, name, dest):
    with open(os.path.join(HERE, "out", "scene.json"), "w", encoding="utf-8") as fh:
        fh.write(blocks[name])
    subprocess.run([sys.executable, "build_view.py", "--template", "viewer.template.html",
                    "--json", "out/scene.json", "--replay", "replay.js",
                    "--out", "out/view.html", "--roots"] + ROOTS,
                   cwd=HERE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    pg.goto("file:///" + os.path.join(HERE, "out", "view.html").replace("\\", "/"),
            wait_until="networkidle")
    pg.wait_for_timeout(140)
    tmp = dest + ".cv.png"
    pg.locator("#cv").screenshot(path=tmp)
    Image.open(tmp).crop((X0, Y0, X1, Y1)).save(dest)
    os.remove(tmp)


os.makedirs(os.path.join(HERE, "out"), exist_ok=True)
with tempfile.TemporaryDirectory() as td:
    cnt = [0]
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page(viewport={"width": 1320, "height": 900})

        def emit(name, reps):
            src = os.path.join(td, "src.png")
            shot(pg, name, src)
            im = Image.open(src)
            for _ in range(reps):
                im.save(os.path.join(td, "f_%04d.png" % cnt[0])); cnt[0] += 1

        emit(names[0], 10)                      # hold the full list
        for n in names[1:-1]:
            emit(n, 2)                          # type the query
        emit(names[-1], 28)                     # hold on the narrowed result
        b.close()

    pat = os.path.join(td, "f_%04d.png")
    pal = os.path.join(td, "pal.png")
    subprocess.run(["ffmpeg", "-y", "-framerate", str(FPS), "-i", pat,
                    "-vf", f"fps={FPS},palettegen=max_colors=128:stats_mode=diff", pal],
                   capture_output=True, check=True)
    subprocess.run(["ffmpeg", "-y", "-framerate", str(FPS), "-i", pat, "-i", pal,
                    "-lavfi", f"fps={FPS}[x];[x][1:v]paletteuse=dither=bayer:diff_mode=rectangle",
                    "-loop", "0", OUT], capture_output=True, check=True)

print("wrote %s  (%d frames @ %dfps, crop %dx%d)" % (OUT, cnt[0], FPS, X1 - X0, Y1 - Y0))
