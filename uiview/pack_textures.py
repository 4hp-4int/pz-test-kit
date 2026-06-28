#!/usr/bin/env python3
"""PZ texture-pack (.pack) WRITER — the inverse of unpack_textures.py.

Builds a v1 .pack with ONE atlas page from a directory of PNGs. Each PNG becomes
a sub-texture whose name is the file's basename (no extension), so a mod that
did getTexture("media/ui/icons/book-unread.png") can instead getTexture(
"book-unread") once the pack is registered (mod.info `pack=<PageName>`).

Format (must match unpack_textures.py exactly):
  [magic "PZPK"] [int32 version==1]
  int32 pageCount (==1)
  page:
    string name              (int32 len + latin-1 bytes)
    int32  numEntries
    int32  hasAlpha (1)
    per entry: string name + 8x int32 (x y w h offX offY fullW fullH)
    int32 pngLen + pngLen bytes   (the atlas PNG)
All ints little-endian. No trim: offX/offY=0, fullW/fullH = w/h.

Usage:
  pack_textures.py build <png_dir> <out.pack> [--page NAME] [--pad N] [--cols N]
  pack_textures.py verify <out.pack> <png_dir>      round-trip every sub-texture
"""
import argparse
import io
import math
import os
import struct
import sys

from PIL import Image

import unpack_textures  # sibling: shares the exact format definition


def _wi(v):
    return struct.pack("<i", v)


def _ws(s):
    b = s.encode("latin-1")
    return _wi(len(b)) + b


def _load(png_dir):
    files = sorted(f for f in os.listdir(png_dir) if f.lower().endswith(".png"))
    return [(os.path.splitext(f)[0],
             Image.open(os.path.join(png_dir, f)).convert("RGBA")) for f in files]


def build(png_dir, out_path, page_name="SauceIcons", pad=2, cols=None, prefix=""):
    imgs = _load(png_dir)
    n = len(imgs)
    if n == 0:
        raise SystemExit("no PNGs in %s" % png_dir)
    if cols is None:
        cols = int(math.ceil(math.sqrt(n)))
    rows = int(math.ceil(n / cols))
    cw = max(im.width for _, im in imgs)
    ch = max(im.height for _, im in imgs)
    atlas_w = pad + cols * (cw + pad)
    atlas_h = pad + rows * (ch + pad)
    atlas = Image.new("RGBA", (atlas_w, atlas_h), (0, 0, 0, 0))

    entries = []
    for i, (name, im) in enumerate(imgs):
        c, r = i % cols, i // cols
        x = pad + c * (cw + pad)
        y = pad + r * (ch + pad)
        atlas.paste(im, (x, y))
        entries.append((prefix + name, x, y, im.width, im.height, 0, 0, im.width, im.height))

    png_buf = io.BytesIO()
    atlas.save(png_buf, format="PNG")
    png = png_buf.getvalue()

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "wb") as f:
        f.write(b"PZPK")
        f.write(_wi(1))            # version
        f.write(_wi(1))            # pageCount
        f.write(_ws(page_name))
        f.write(_wi(len(entries)))
        f.write(_wi(1))            # hasAlpha
        for e in entries:
            f.write(_ws(e[0]))
            for v in e[1:]:
                f.write(_wi(v))
        f.write(_wi(len(png)))
        f.write(png)
    return n, (atlas_w, atlas_h), os.path.getsize(out_path)


def verify(pack_path, png_dir, prefix=""):
    pk = unpack_textures.Pack(pack_path)
    names = set(pk.names())
    imgs = _load(png_dir)
    bad = 0
    for name, orig in imgs:
        pname = prefix + name
        if pname not in names:
            print("MISSING in pack: %s" % pname)
            bad += 1
            continue
        got = pk.extract(pname)
        if got.size != orig.size or got.tobytes() != orig.tobytes():
            print("MISMATCH: %s  (orig %s vs pack %s)" % (name, orig.size, got.size))
            bad += 1
    print("verified %d sub-textures, %d bad" % (len(imgs), bad))
    return bad == 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("png_dir")
    b.add_argument("out")
    b.add_argument("--page", default="SauceIcons")
    b.add_argument("--pad", type=int, default=2)
    b.add_argument("--cols", type=int, default=None)
    b.add_argument("--prefix", default="")
    v = sub.add_parser("verify")
    v.add_argument("pack")
    v.add_argument("png_dir")
    v.add_argument("--prefix", default="")
    args = ap.parse_args()

    if args.cmd == "build":
        n, size, nbytes = build(args.png_dir, args.out, args.page, args.pad,
                                 args.cols, args.prefix)
        print("packed %d icons -> %s  (atlas %dx%d, %d bytes)"
              % (n, args.out, size[0], size[1], nbytes))
    elif args.cmd == "verify":
        ok = verify(args.pack, args.png_dir, args.prefix)
        sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
