#!/usr/bin/env python3
"""UIView shell builder — inline replay core + base64 icons + frame JSON.

Produces a self-contained HTML (no server, no CORS, works under file:// and
Playwright set_content) by replacing three tokens in a shell template:

    /*__REPLAY__*/   -> contents of replay.js (canonical draw core)
    /*__ASSETS__*/   -> { "media/.../foo.png": "data:image/png;base64,..." }
    /*__FRAME__*/    -> the frame (or storyboard) JSON

Texture asset names are discovered from the JSON ("name":"....png") and base64
inlined from the first asset root that contains them. Missing files are simply
omitted (the replay core draws a placeholder box for unresolved textures).

Usage:
    build_view.py --template T --json F --replay R --out O
                  [--roots r1 r2 ...] [--default-frame '{...}']
"""
import argparse
import base64
import json
import mimetypes
import os
import sys

import unpack_textures  # PZ .pack reader/extractor (sibling module)

# Extracted PZ item icons are cached here so only the first build pays the pack
# scan; later builds resolve them as plain files.
ICON_CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".iconcache")
# Packs most likely to hold inventory item icons, searched first.
PACK_ORDER = ["UI", "UI2", "ApCom", "ApComUI", "IconsMoveables", "Mechanics", "RadioIcons"]

_pack_cache = {}      # pack name -> Pack (process-local)
_pack_miss = set()    # icon names already searched and not found


def _walk_frames(node, out):
    """Yield every {ops:[...]} frame inside a single-frame OR storyboard JSON."""
    if isinstance(node, dict):
        if isinstance(node.get("ops"), list):
            out.append(node)
        if isinstance(node.get("frames"), list):
            for b in node["frames"]:
                _walk_frames(b.get("frame", b), out)


def discover_textures(blob: str):
    """Texture-op asset names (file paths AND bare PZ subtexture names)."""
    try:
        data = json.loads(blob)
    except ValueError:
        return []
    frames = []
    _walk_frames(data, frames)
    seen, out = set(), []
    for fr in frames:
        for op in fr["ops"]:
            # texture_tiled needs its source resolved exactly like texture --
            # the replayer builds a canvas pattern from the same image. Missing
            # it here does not fail loudly, it silently draws the "asset not
            # found" placeholder over the whole tiled region.
            if op.get("op") in ("texture", "texture_tiled"):
                name = op.get("name")
                if name and name not in seen:
                    seen.add(name)
                    out.append(name)
    return out


def _resolve_file(name, roots):
    """A real file under an asset root (mod UI textures, phosphor icons)."""
    rel = name.lstrip("/")
    for root in roots:
        cand = os.path.join(root, rel)
        if os.path.isfile(cand):
            return cand
    return None


def _resolve_pack_icon(name):
    """Extract a PZ item icon from the texture packs (cached to disk).

    Accepts a bare subtexture name ("Item_Bandage") or a path whose basename is
    one. Returns a cached PNG path or None."""
    base = os.path.splitext(os.path.basename(name))[0]
    if not base or base in _pack_miss:
        return None
    cached = os.path.join(ICON_CACHE, base + ".png")
    if os.path.isfile(cached):
        return cached
    packs = PACK_ORDER + [p for p in unpack_textures.all_packs() if p not in PACK_ORDER]
    for pack in packs:
        pk = _pack_cache.get(pack)
        if pk is None:
            try:
                pk = unpack_textures.Pack(unpack_textures.pack_path(pack))
            except Exception:
                pk = False
            _pack_cache[pack] = pk
        if not pk:
            continue
        im = pk.extract(base)
        if im is not None:
            os.makedirs(ICON_CACHE, exist_ok=True)
            im.save(cached)
            return cached
    _pack_miss.add(base)
    return None


_mod_pack_cache = {}   # pack file path -> Pack or False


def _resolve_mod_pack(name, roots):
    """Resolve a bare sub-texture name (e.g. "sir_book-unread") from a mod's own
    .pack under <root>/media/texturepacks/. This is how SIR ships its icons, so
    the harness renders from the EXACT pack the game loads (true parity).

    Always re-extracts (no skip-if-cached) so a rebuilt pack is picked up."""
    base = os.path.basename(name)
    for root in roots:
        tpdir = os.path.join(root, "media", "texturepacks")
        if not os.path.isdir(tpdir):
            continue
        for fn in sorted(os.listdir(tpdir)):
            if not fn.endswith(".pack"):
                continue
            pp = os.path.join(tpdir, fn)
            pk = _mod_pack_cache.get(pp)
            if pk is None:
                try:
                    pk = unpack_textures.Pack(pp)
                except Exception:
                    pk = False
                _mod_pack_cache[pp] = pk
            if not pk:
                continue
            im = pk.extract(base)
            if im is not None:
                os.makedirs(ICON_CACHE, exist_ok=True)
                out = os.path.join(ICON_CACHE, "_mp_" + base + ".png")
                im.save(out)
                return out
    return None


def _resolve_prefixed_file(name, roots):
    """Fallback: map a "sir_<name>" sub-texture back to the loose PNG that fed the
    pack (build/icons/<name>.png — build-only, not shipped), so the harness still
    renders if the pack is missing or stale."""
    if name.startswith("sir_"):
        return _resolve_file("build/icons/" + name[4:] + ".png", roots)
    return None


def build_asset_map(names, roots):
    assets = {}
    missing = []
    for name in names:
        found = (_resolve_file(name, roots)
                 or _resolve_mod_pack(name, roots)
                 or _resolve_prefixed_file(name, roots)
                 or _resolve_pack_icon(name))
        if not found:
            missing.append(name)
            continue
        mime = mimetypes.guess_type(found)[0] or "image/png"
        with open(found, "rb") as fh:
            b64 = base64.b64encode(fh.read()).decode("ascii")
        assets[name] = "data:%s;base64,%s" % (mime, b64)
    return assets, missing


def inline_value(text: str, token: str, value: str) -> str:
    """Replace `token` with `value` and comment out the rest of that line, so a
    trailing default literal (e.g. `/*__FRAME__*/{...default...}`) is neutralized
    by line-comment. Only safe when the token sits in expression position with
    its default to the end of the line."""
    if token not in text:
        sys.stderr.write("[build_view] WARN: token %s not found\n" % token)
        return text
    return text.replace(token, value + "//", 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--template", required=True)
    ap.add_argument("--json", required=True, help="frame/storyboard JSON file")
    ap.add_argument("--replay", required=True, help="replay.js path")
    ap.add_argument("--out", required=True)
    ap.add_argument("--roots", nargs="*", default=[], help="asset search roots")
    args = ap.parse_args()

    tpl = open(args.template, encoding="utf-8").read()
    data = open(args.json, encoding="utf-8").read().strip()
    replay = open(args.replay, encoding="utf-8").read()

    names = discover_textures(data)
    assets, missing = build_asset_map(names, args.roots)
    if missing:
        sys.stderr.write("[build_view] %d texture(s) had no file (placeholder): %s\n"
                         % (len(missing), ", ".join(missing[:6]) + ("..." if len(missing) > 6 else "")))

    # FRAME / ASSETS sit in expression position with a same-line default that we
    # neutralize by line-comment. REPLAY is inside its own <script>, plain drop.
    out = inline_value(tpl, "/*__FRAME__*/", data)
    out = inline_value(out, "/*__ASSETS__*/", json.dumps(assets))
    out = out.replace("/*__REPLAY__*/", replay, 1)

    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(out)
    print("[build_view] wrote %s  (%d icons inlined, %d ops)"
          % (args.out, len(assets), data.count('"op":')), file=sys.stderr)


if __name__ == "__main__":
    main()
