#!/usr/bin/env python3
"""
Generate UIView/FontMetrics.lua from PZ's real AngelCode bitmap fonts.
=====================================================================

WHY THIS EXISTS
---------------
UIMock measured text as `#string * averageGlyphWidth`. Every uiview preview
therefore flowed on an approximation while the game flows on
`TextManager.MeasureStringX`, which is exact. For short labels the error is
invisible; for a wrapped paragraph it accumulates until the preview shows a
comfortable column and the game shows a line running off the card. That is the
worst failure a preview can have -- not "looks slightly different" but
"confidently predicts the wrong layout", which is how a journal page got
signed off in the mock and shipped overflowing.

THE ALGORITHM, matched exactly
------------------------------
zombie/core/textures/AngelCodeFont.getWidth(text, start, end, xadvance=false),
which is what MeasureStringX calls:

    for each char:
        newline (10)      -> width = 0
        unknown id        -> skipped entirely
        otherwise         -> width += kerning(prev, this)
                             width += (last char and not xadvance)
                                        ? charDef.width      <-- NOT xadvance
                                        : charDef.xadvance
        maxWidth = max(maxWidth, width)

Two details that a naive "sum the advances" gets wrong, and both matter:
  * the FINAL glyph contributes its ink `width`, not its `xadvance`;
  * an unknown codepoint contributes NOTHING (it is not a fallback glyph).
PZ's shipped .fnt files carry no kerning pairs at all (verified: 0 in every
size of every font), so kerning is emitted but always empty.

FONT SIZE
---------
PZ picks a size directory from the font-size option
(TextManager.java:207-217): 2->1x, 3->2x, 4->3x, 5->4x. All four are emitted;
the harness selects one, so a preview can be checked at the size the player
actually runs rather than at whatever the generator happened to see.

OUTPUT is committed. The harness must run on CI, which has no PZ install --
same reasoning as the generated weapon_scripts.lua. Re-run after a PZ update.
"""
import os
import re
import sys

# Only the fonts a UI actually draws with. The full list includes SDF and
# main-menu faces no panel uses, and each one is ~200 lines of table.
WANTED = [
    "Small", "Medium", "Large",
    "NewSmall", "NewMedium", "NewLarge",
    "Title", "Massive", "Code", "Cred1", "Cred2",
    "CodeSmall", "CodeMedium", "CodeLarge",
    "Dialogue", "Handwritten",
]

SIZE_DIRS = ["1x", "2x", "3x", "4x"]

# ASCII printable. Everything else falls back to a per-font average, which is
# honest for CJK/Cyrillic previews and exact for the English ones we judge.
FIRST, LAST = 32, 126


def find_pz():
    env = os.environ.get("PZ_INSTALL_DIR")
    if env and os.path.isdir(os.path.join(env, "media", "fonts")):
        return env
    for c in [
        r"C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid",
        r"C:\Program Files\Steam\steamapps\common\ProjectZomboid",
        os.path.expanduser("~/.steam/steam/steamapps/common/ProjectZomboid"),
    ]:
        if os.path.isdir(os.path.join(c, "media", "fonts")):
            return c
    return None


def parse_fonts_txt(path):
    """font Name { fnt = file.fnt, ... }  ->  {Name: file.fnt}"""
    out = {}
    name = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = re.match(r"\s*font\s+(\S+)", line)
            if m:
                name = m.group(1)
                continue
            m = re.match(r"\s*fnt\s*=\s*(\S+?),?\s*$", line)
            if m and name:
                out[name] = m.group(1)
                name = None
    return out


def parse_fnt(path):
    """-> (lineHeight, base, {id: (xadvance, width)}, kerning_count)

    `base` is the distance from the top of the line box down to the baseline.
    The viewer needs it to place glyphs vertically the way PZ does: without it
    a rule positioned against the middle of a line (a strike-through) renders
    below the letters as an underline, which is a completely different signal.
    """
    line_height = 0
    base = 0
    chars = {}
    kerning = 0
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.startswith("common "):
                m = re.search(r"lineHeight=(-?\d+)", line)
                if m:
                    line_height = int(m.group(1))
                m = re.search(r"base=(-?\d+)", line)
                if m:
                    base = int(m.group(1))
            elif line.startswith("char "):
                d = dict(re.findall(r"(\w+)=(-?\d+)", line))
                if "id" in d:
                    chars[int(d["id"])] = (
                        int(d.get("xadvance", 0)), int(d.get("width", 0)))
            elif line.startswith("kerning "):
                kerning += 1
    return line_height, base, chars, kerning


def lua_escape_key(cp):
    return str(cp)


def main():
    pz = find_pz()
    if not pz:
        print("PZ install not found. Set PZ_INSTALL_DIR.", file=sys.stderr)
        return 1

    fonts_dir = os.path.join(pz, "media", "fonts", "EN")
    mapping = parse_fonts_txt(os.path.join(fonts_dir, "fonts.txt"))

    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_path = os.path.join(
        here, "media", "lua", "client", "UIView", "FontMetrics.lua")

    total_kerning = 0
    blocks = []
    for size in SIZE_DIRS:
        entries = []
        for font in WANTED:
            fnt = mapping.get(font)
            if not fnt:
                continue
            p = os.path.join(fonts_dir, size, fnt)
            if not os.path.isfile(p):
                continue
            lh, base, chars, kern = parse_fnt(p)
            total_kerning += kern

            adv, wid = [], []
            present = 0
            adv_sum = 0
            for cp in range(FIRST, LAST + 1):
                c = chars.get(cp)
                if c:
                    adv.append(f"[{lua_escape_key(cp)}]={c[0]}")
                    wid.append(f"[{lua_escape_key(cp)}]={c[1]}")
                    present += 1
                    adv_sum += c[0]
            fallback = round(adv_sum / present) if present else 6

            def wrap(items, indent="                "):
                out, line = [], ""
                for it in items:
                    if len(line) + len(it) + 2 > 76:
                        out.append(indent + line)
                        line = ""
                    line += it + ", "
                if line:
                    out.append(indent + line)
                return "\n".join(out)

            entries.append(
                f'        ["{font}"] = {{\n'
                f"            h = {lh}, base = {base}, fallback = {fallback},\n"
                f"            adv = {{\n{wrap(adv)}\n            }},\n"
                f"            wid = {{\n{wrap(wid)}\n            }},\n"
                f"        }},"
            )
        blocks.append(f'    ["{size}"] = {{\n' + "\n".join(entries) + "\n    },")

    header = f'''-- ============================================================================
-- UIView/FontMetrics.lua — GENERATED, do not edit by hand
-- ============================================================================
-- Source: PZ's own AngelCode bitmap fonts (media/fonts/EN/<size>/*.fnt).
-- Regenerate with: python uiview/tools/gen_font_metrics.py
--
-- Per-glyph advance and ink widths for ASCII 32..126, at each of PZ's four
-- font-size directories. UIMock sums these exactly the way
-- AngelCodeFont.getWidth does, so a preview flows on the same numbers the game
-- flows on -- rather than on an average-glyph-width guess that drifts a little
-- further with every word and lands a wrapped paragraph off the edge of the
-- card.
--
-- `fallback` is the mean advance, used for codepoints outside the table (CJK,
-- Cyrillic). Those previews stay approximate; the English ones are exact.
--
-- Kerning pairs found across every shipped font/size: {total_kerning}. PZ's
-- fonts carry none, so measurement is advances plus the final glyph's width.
-- ============================================================================

return {{
'''
    body = "\n".join(blocks) + "\n}\n"

    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(header + body)

    size_kb = os.path.getsize(out_path) / 1024.0
    print(f"wrote {out_path} ({size_kb:.0f} KB, {len(SIZE_DIRS)} sizes, "
          f"{len(WANTED)} fonts requested, kerning pairs: {total_kerning})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
