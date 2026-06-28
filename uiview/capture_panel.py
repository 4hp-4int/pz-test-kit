#!/usr/bin/env python3
"""Capture a clean PNG of just the rendered panel from a built UIView scene.

Unlike shoot.py (which screenshots the whole viewer page, chrome and all),
this loads out/view.html, screenshots only the <canvas>, and crops to the
root element's bounding box (read from out/scene.json) so the result is a
tight, transparent-margin product shot of the real UI — ready to drop into
a promo card.

    capture_panel.py <png_out> [--zoom N] [--pad P] [--scene-json path]
"""
import json
import os
import sys

from PIL import Image
from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    out = os.path.abspath(sys.argv[1])
    zoom = 3
    pad = 0
    scene_json = os.path.join(HERE, "out", "scene.json")
    view_html = os.path.join(HERE, "out", "view.html")
    a = sys.argv[2:]
    i = 0
    while i < len(a):
        if a[i] == "--zoom":
            zoom = int(a[i + 1]); i += 2
        elif a[i] == "--pad":
            pad = int(a[i + 1]); i += 2
        elif a[i] == "--scene-json":
            scene_json = os.path.abspath(a[i + 1]); i += 2
        elif a[i] == "--html":
            view_html = os.path.abspath(a[i + 1]); i += 2
        else:
            i += 1

    scene = json.load(open(scene_json))
    root = scene.get("tree") or {}
    rx, ry = root.get("x", 0), root.get("y", 0)
    rw, rh = root.get("w", scene["width"]), root.get("h", scene["height"])

    url = "file:///" + view_html.replace("\\", "/")
    raw = os.path.join(HERE, "out", "_cap_raw.png")
    with sync_playwright() as p:
        b = p.chromium.launch()
        page = b.new_page(viewport={"width": 1600, "height": 1100},
                          device_scale_factor=1)
        page.goto(url, wait_until="networkidle")
        # Drive the canvas at a fixed zoom, then read the bitmap back via
        # toDataURL — pixel-exact, immune to stage scroll / element-screenshot
        # offsets. Crop is then a plain slice of the known canvas bitmap.
        data = page.evaluate(
            "(z)=>{ZOOM=z; if(window.draw) draw();"
            " return document.getElementById('cv').toDataURL('image/png');}",
            zoom)
        b.close()

    import base64
    with open(raw, "wb") as f:
        f.write(base64.b64decode(data.split(",", 1)[1]))

    img = Image.open(raw).convert("RGBA")
    L = max(0, int((rx - pad) * zoom))
    T = max(0, int((ry - pad) * zoom))
    R = min(img.width, int((rx + rw + pad) * zoom))
    B = min(img.height, int((ry + rh + pad) * zoom))
    img.crop((L, T, R, B)).save(out)
    os.remove(raw)
    print("[capture] %s  (%dx%d @ zoom %d, bbox %d,%d,%d,%d)"
          % (out, R - L, B - T, zoom, rx, ry, rw, rh))


if __name__ == "__main__":
    main()
