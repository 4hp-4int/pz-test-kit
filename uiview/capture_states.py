#!/usr/bin/env python3
"""Capture each SaucePalette state plate from out/states-single.html as its own PNG.

The plates are painted into canvases at 2x device pixels with the stage checker
baked in, so the capture is a plain toDataURL read of each canvas bitmap — no
element screenshot, no device_scale_factor, nothing that can drift.

    capture_states.py [--html out/states-single.html] [--outdir DIR]
                      [--prefix sso-state-] [--suffix -2x]
"""
import argparse
import base64
import json
import os
import sys

from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--html", default=os.path.join(HERE, "out", "states-single.html"))
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--prefix", default="sso-state-")
    ap.add_argument("--suffix", default="-2x")
    args = ap.parse_args()

    html = os.path.abspath(args.html)
    outdir = os.path.abspath(args.outdir)
    os.makedirs(outdir, exist_ok=True)
    url = "file:///" + html.replace("\\", "/")

    with sync_playwright() as p:
        b = p.chromium.launch()
        page = b.new_page(viewport={"width": 1400, "height": 1000},
                          device_scale_factor=1)
        errs = []
        page.on("pageerror", lambda e: errs.append(str(e)))
        page.goto(url, wait_until="load")
        page.wait_for_function("window.__ready === true", timeout=60000)
        plates = page.evaluate("window.__plates")
        written = []
        for pl in plates:
            data = page.evaluate(
                "(id)=>document.getElementById(id).toDataURL('image/png')", pl["id"])
            label = pl["id"][len("st-"):]
            name = args.prefix + label + args.suffix + ".png"
            path = os.path.join(outdir, name)
            with open(path, "wb") as fh:
                fh.write(base64.b64decode(data.split(",", 1)[1]))
            written.append((path, pl["w"], pl["h"], pl["full"], pl["crop"]))
        b.close()

    if errs:
        sys.stderr.write("[capture_states] page errors: %s\n" % "; ".join(errs))
    for path, w, h, full, crop in written:
        print("%s  %dx%d  crop=%s%s" % (path, w, h, crop, "  [unclipped variant]" if full else ""))
    print("[capture_states] %d plate(s) -> %s" % (len(written), outdir), file=sys.stderr)
    print(json.dumps([p[0] for p in written]), file=sys.stderr)


if __name__ == "__main__":
    main()
