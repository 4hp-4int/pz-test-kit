#!/usr/bin/env python3
"""Screenshot a built UIView HTML to PNG (for headless iteration).

    shoot.py <html> <png> [width height]      # viewer: full page
    shoot.py <html> <png> --seek <t>           # player: drive seek(t), shoot #stage
"""
import os
import sys
from playwright.sync_api import sync_playwright


def main():
    html = os.path.abspath(sys.argv[1])
    png = os.path.abspath(sys.argv[2])
    seek = None
    w, h = 1320, 868
    args = sys.argv[3:]
    i = 0
    while i < len(args):
        if args[i] == "--seek":
            seek = float(args[i + 1]); i += 2
        else:
            w = int(args[i]); h = int(args[i + 1]); i += 2
    url = "file:///" + html.replace("\\", "/")
    with sync_playwright() as p:
        browser = p.chromium.launch()
        if seek is not None:
            page = browser.new_page(viewport={"width": 1920, "height": 1080})
            page.add_init_script("window.__capture = true;")
            page.goto(url, wait_until="networkidle")
            page.evaluate("window.__ready")          # await icon preload
            page.evaluate("window.PLAYER.seek(%f)" % seek)
            page.wait_for_timeout(60)
            page.locator("#stage").screenshot(path=png)
        else:
            page = browser.new_page(viewport={"width": w, "height": h})
            page.goto(url, wait_until="networkidle")
            page.wait_for_timeout(450)
            page.screenshot(path=png, type="png", full_page=True)
        browser.close()
    print("[shoot] %s -> %s%s" % (html, png, ("  seek=%s" % seek) if seek is not None else ""))


if __name__ == "__main__":
    main()
