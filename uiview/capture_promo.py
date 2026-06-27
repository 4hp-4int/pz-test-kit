#!/usr/bin/env python3
"""Crop the CURRENT UIView render (out/view.html + out/scene.json) to a clean panel PNG.

    ./uiview.sh <scene> && python capture_promo.py <scene>

Run uiview.sh first (it builds out/ for that scene), then this. We element-screenshot
the #cv canvas — which never includes sibling HTML except the inspector's NOTES panel
overlapping the canvas's right edge — then crop to the panel: fixed X (panel left ..
just before that NOTES overlay) and a dynamic height from the display-list bounding box,
so any row count crops tight. Driven per-scene from a shell loop (uiview.sh's set -e
makes it awkward to call under subprocess).
"""
import json
import os
import sys

from playwright.sync_api import sync_playwright
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))

# Panel spans canvas x 218..1062, but the viewer's NOTES sidebar overlays from ~985.
# Crop left of it; the detail pane's text ends well before 974.
X0, X1 = 216, 974


def capture(scene):
    frame = json.load(open(os.path.join(HERE, "out", "scene.json")))
    boxed = [o for o in frame["ops"] if "w" in o and "h" in o]   # rects bound the panel
    y0 = max(0, int(min(o["y"] for o in boxed)) - 3)
    y1 = int(max(o["y"] + o["h"] for o in boxed)) + 3

    html = "file:///" + os.path.join(HERE, "out", "view.html").replace("\\", "/")
    tmp = os.path.join(HERE, "shots", "_tmp.png")
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page(viewport={"width": 1320, "height": 900})
        pg.goto(html, wait_until="networkidle")
        pg.wait_for_timeout(500)
        pg.locator("#cv").screenshot(path=tmp)
        b.close()

    out = os.path.join(HERE, "shots", scene + ".png")
    Image.open(tmp).crop((X0, y0, X1, y1)).save(out)
    os.remove(tmp)
    print("wrote %-18s %dx%d" % (scene, X1 - X0, y1 - y0))


if __name__ == "__main__":
    capture(sys.argv[1])
