#!/usr/bin/env python3
"""PZ texture-pack (.pack) reader / extractor.

Implements the exact format from the decompiled loader
(zombie.fileSystem.TexturePackDevice + zombie.core.textures.TexturePackPage):

  [magic "PZPK" (80 90 80 75)] [int32 version==1]   (absent => version 0)
  int32 pageCount
  per page:
    string name            (int32 len + len bytes, 1 byte/char)
    int32  numEntries
    int32  hasAlpha (bool)
    per entry: string name + 8x int32 (x y w h offX offY fullW fullH)
    v0: raw PNG bytes terminated by little-endian 0xDEADBEEF (EF BE AD DE)
    v1: int32 pngLen + pngLen bytes of PNG

All ints little-endian. Each page is a PNG atlas; sub-textures are rects in it.

Usage:
  unpack_textures.py packs                     list packs in the install
  unpack_textures.py list  <pack>              page summary
  unpack_textures.py names <pack> [--grep S]   sub-texture names
  unpack_textures.py find  <substr> [--packs a b]   search names across packs
  unpack_textures.py extract <pack> <name> <out.png> [--trim]
  unpack_textures.py batch <outdir> name1 name2 ...   (auto-find across packs)
"""
import argparse
import io
import os
import struct
import sys

from PIL import Image

PZ_TEXPACKS = r"C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\media\texturepacks"
DEADBEEF = b"\xef\xbe\xad\xde"


def _ri(f):
    b = f.read(4)
    if len(b) < 4:
        raise EOFError("unexpected EOF reading int")
    return struct.unpack("<i", b)[0]


def _rs(f):
    n = _ri(f)
    return f.read(n).decode("latin-1")


class Pack:
    def __init__(self, path):
        self.path = path
        self.version = 0
        self.pages = []  # {name, hasAlpha, sub[], png_off, png_len}
        self._page_img = {}  # name -> PIL.Image (lazy)
        self._sub = {}       # subname -> (page, info)
        self._parse()

    def _parse(self):
        with open(self.path, "rb") as f:
            magic = f.read(4)
            if magic == b"PZPK":
                self.version = _ri(f)
                if not (1 <= self.version <= 1):
                    raise IOError("unsupported .pack version %d" % self.version)
            else:
                f.seek(0)
                self.version = 0
            count = _ri(f)
            for _ in range(count):
                self.pages.append(self._read_page(f))
        for pg in self.pages:
            for s in pg["sub"]:
                self._sub.setdefault(s["name"], (pg, s))

    def _read_page(self, f):
        name = _rs(f)
        num = _ri(f)
        has_alpha = _ri(f) != 0
        sub = []
        for _ in range(num):
            en = _rs(f)
            x, y, w, h = _ri(f), _ri(f), _ri(f), _ri(f)
            ox, oy, fx, fy = _ri(f), _ri(f), _ri(f), _ri(f)
            sub.append(dict(name=en, x=x, y=y, w=w, h=h, ox=ox, oy=oy, fx=fx, fy=fy))
        if self.version == 0:
            start = f.tell()
            rest = f.read()
            idx = rest.find(DEADBEEF)
            if idx < 0:
                raise IOError("v0 page %s: no 0xDEADBEEF terminator" % name)
            png_off, png_len = start, idx
            f.seek(start + idx + 4)
        else:
            png_len = _ri(f)
            png_off = f.tell()
            f.seek(png_off + png_len)
        return dict(name=name, hasAlpha=has_alpha, sub=sub, png_off=png_off, png_len=png_len)

    def page_image(self, pg):
        key = pg["name"]
        if key not in self._page_img:
            with open(self.path, "rb") as f:
                f.seek(pg["png_off"])
                data = f.read(pg["png_len"])
            self._page_img[key] = Image.open(io.BytesIO(data)).convert("RGBA")
        return self._page_img[key]

    def names(self):
        return sorted(self._sub.keys())

    def extract(self, name, trim=False):
        if name not in self._sub:
            return None
        pg, s = self._sub[name]
        img = self.page_image(pg)
        crop = img.crop((s["x"], s["y"], s["x"] + s["w"], s["y"] + s["h"]))
        if trim or not (s["fx"] > 0 and s["fy"] > 0 and (s["fx"] > s["w"] or s["fy"] > s["h"])):
            return crop
        # pad the trimmed sprite back into its full original frame (in-game slot)
        full = Image.new("RGBA", (s["fx"], s["fy"]), (0, 0, 0, 0))
        full.paste(crop, (s["ox"], s["oy"]))
        return full


def all_packs():
    if not os.path.isdir(PZ_TEXPACKS):
        return []
    return sorted(f[:-5] for f in os.listdir(PZ_TEXPACKS) if f.endswith(".pack"))


def pack_path(pack):
    return pack if pack.endswith(".pack") else os.path.join(PZ_TEXPACKS, pack + ".pack")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("packs")
    p = sub.add_parser("list"); p.add_argument("pack")
    p = sub.add_parser("names"); p.add_argument("pack"); p.add_argument("--grep", default=None)
    p = sub.add_parser("find"); p.add_argument("substr"); p.add_argument("--packs", nargs="*", default=None)
    p = sub.add_parser("extract"); p.add_argument("pack"); p.add_argument("name"); p.add_argument("out"); p.add_argument("--trim", action="store_true")
    p = sub.add_parser("batch"); p.add_argument("outdir"); p.add_argument("names", nargs="+"); p.add_argument("--packs", nargs="*", default=None); p.add_argument("--trim", action="store_true")
    args = ap.parse_args()

    if args.cmd == "packs":
        for name in all_packs():
            print(name)
        return

    if args.cmd == "list":
        pk = Pack(pack_path(args.pack))
        print("version=%d  pages=%d  subtextures=%d" % (pk.version, len(pk.pages), len(pk._sub)))
        for pg in pk.pages:
            print("  page %-28s alpha=%s  entries=%d" % (pg["name"], pg["hasAlpha"], len(pg["sub"])))
        return

    if args.cmd == "names":
        pk = Pack(pack_path(args.pack))
        for n in pk.names():
            if not args.grep or args.grep.lower() in n.lower():
                print(n)
        return

    if args.cmd == "find":
        packs = args.packs or all_packs()
        s = args.substr.lower()
        for pack in packs:
            try:
                pk = Pack(pack_path(pack))
            except Exception as e:
                print("  (skip %s: %s)" % (pack, e), file=sys.stderr)
                continue
            hits = [n for n in pk.names() if s in n.lower()]
            if hits:
                print("== %s (%d) ==" % (pack, len(hits)))
                for n in hits[:60]:
                    print("   " + n)
        return

    if args.cmd == "extract":
        pk = Pack(pack_path(args.pack))
        im = pk.extract(args.name, trim=args.trim)
        if im is None:
            print("not found: %s in %s" % (args.name, args.pack), file=sys.stderr)
            sys.exit(1)
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        im.save(args.out)
        print("%s -> %s (%dx%d)" % (args.name, args.out, im.width, im.height))
        return

    if args.cmd == "batch":
        os.makedirs(args.outdir, exist_ok=True)
        packs = args.packs or all_packs()
        loaded = {}
        for pack in packs:
            try:
                loaded[pack] = Pack(pack_path(pack))
            except Exception:
                pass
        for name in args.names:
            done = False
            for pack, pk in loaded.items():
                im = pk.extract(name)
                if im is not None:
                    out = os.path.join(args.outdir, name + ".png")
                    im.save(out)
                    print("%-26s <- %-16s (%dx%d)" % (name, pack, im.width, im.height))
                    done = True
                    break
            if not done:
                print("MISS %s" % name, file=sys.stderr)
        return


if __name__ == "__main__":
    main()
