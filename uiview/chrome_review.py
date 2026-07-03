#!/usr/bin/env python3
"""Chrome review — the pack + surface contact sheet ("pz-playwright-lite").

One HTML page (+ PNG shot) answering "what chrome do we ship, per mod, and
what do the surfaces wearing it look like?":

  * per PACK: every subtexture as a swatch (real pixels, extracted from the
    .pack), grouped by family, with names + sizes — reviewable at a glance,
    and drift between mods' shared-design families is visible side by side
  * per SURFACE: the golden-scene shots (inventory, palette skins, tooltip
    cards...) rendered from those same packs

    python chrome_review.py                 # build out/chrome-review.html + shot
    python chrome_review.py --no-shot       # HTML only

Packs reviewed come from the chrome registry's mods (promo/chrome-registry.json)
plus any extra --pack arguments.
"""
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REGISTRY = os.path.normpath(os.path.join(HERE, "..", "..", "promo", "chrome-registry.json"))
STAGE = os.path.join(HERE, "out", "chrome-review")
OUT_HTML = os.path.join(HERE, "out", "chrome-review.html")
OUT_PNG = os.path.join(HERE, "shots", "chrome-review.png")

# golden-scene shots to embed as the "surfaces" section, when present
SURFACE_SHOTS = [
    ("SIR inventory (per-mod SIRChrome + SIRIcons)", "sirinv_foundry.png"),
    ("SSO order box (per-mod SSOChrome)", "palette_foundry.png"),
    ("Tooltip card (kraft + cherry rail)", "tooltipdressitem.png"),
    ("Tooltip card (accent rail)", "tooltipdressitemaccent.png"),
    ("Object tooltip card", "tooltipdress.png"),
]

DARK = "#17181d"


def family(name):
    """sir_ledger_crm_tl -> ledger_crm; sso_star_fill -> star_fill."""
    base = re.sub(r"^(sir|sso|vps|sauce)_", "", name)
    m = re.match(r"^(.*)_(tl|t|tr|l|r|bl|b|br|c|m)$", base)
    return m.group(1) if m else base


def unpack(pack, dest):
    tool = os.path.join(HERE, "unpack_textures.py")
    names = subprocess.run([sys.executable, tool, "names", pack],
                           check=True, capture_output=True, text=True)
    names = [n.strip() for n in names.stdout.splitlines() if n.strip()]
    os.makedirs(dest, exist_ok=True)
    subprocess.run([sys.executable, tool, "batch", dest] + names + ["--packs", pack],
                   check=True, capture_output=True, text=True)
    return names


def swatch_grid(pack_label, pack_path, names, rel_dir):
    fams = {}
    for n in sorted(names):
        fams.setdefault(family(n), []).append(n)
    kb = os.path.getsize(pack_path) / 1024.0
    h = [f'<section><h2>{pack_label} <small>{len(names)} subtextures - {kb:.0f} KB - '
         f'{os.path.basename(pack_path)}</small></h2>']
    for fam in sorted(fams):
        h.append(f'<h3>{fam} <small>{len(fams[fam])}</small></h3><div class="grid">')
        for n in fams[fam]:
            h.append(f'<figure><div class="cell"><img src="{rel_dir}/{n}.png" alt="{n}"></div>'
                     f'<figcaption>{n}</figcaption></figure>')
        h.append("</div>")
    h.append("</section>")
    return "\n".join(h)


def main():
    with open(REGISTRY) as f:
        reg = json.load(f)

    if os.path.isdir(STAGE):
        shutil.rmtree(STAGE)
    os.makedirs(STAGE, exist_ok=True)

    sections = []
    for mod_id, mod in reg["mods"].items():
        for rel in mod["manifestPacks"]:
            pack = os.path.normpath(os.path.join(os.path.dirname(REGISTRY), rel))
            if not os.path.exists(pack):
                print(f"[review] missing pack skipped: {pack}")
                continue
            page = os.path.splitext(os.path.basename(pack))[0]
            dest = os.path.join(STAGE, page)
            names = unpack(pack, dest)
            sections.append(swatch_grid(f"{mod_id.upper()} - {page}", pack, names,
                                        f"chrome-review/{page}"))
            print(f"[review] {page}: {len(names)} swatches")

    surfaces = ['<section><h2>Surfaces wearing the chrome</h2>']
    for label, shot in SURFACE_SHOTS:
        p = os.path.join(HERE, "shots", shot)
        if os.path.exists(p):
            surfaces.append(f'<figure class="surface"><img src="../shots/{shot}">'
                            f'<figcaption>{label}</figcaption></figure>')
    surfaces.append("</section>")

    html = f"""<!doctype html><meta charset="utf-8"><title>Sauce chrome review</title>
<style>
  body {{ background:{DARK}; color:#cfd2da; font:13px/1.5 'Cascadia Code',monospace; margin:24px; }}
  h1 {{ color:#e8e2d4; }} h2 {{ color:#e8b04a; margin-top:32px; }}
  h3 {{ color:#9aa0ad; margin:18px 0 6px; }} small {{ color:#6d7280; font-weight:normal; }}
  .grid {{ display:flex; flex-wrap:wrap; gap:10px; }}
  figure {{ margin:0; width:96px; text-align:center; }}
  .cell {{ background:
      repeating-conic-gradient(#22242b 0% 25%, #1b1d23 0% 50%) 0 0/16px 16px;
      border:1px solid #2c2f38; border-radius:4px; height:72px;
      display:flex; align-items:center; justify-content:center; }}
  .cell img {{ max-width:88px; max-height:64px; image-rendering:pixelated; }}
  figcaption {{ font-size:10px; color:#8a8f9c; word-break:break-all; margin-top:2px; }}
  .surface {{ width:auto; display:inline-block; vertical-align:top; margin:8px; }}
  .surface img {{ max-width:420px; border:1px solid #2c2f38; border-radius:6px; }}
  .surface figcaption {{ font-size:12px; }}
</style>
<h1>Sauce chrome review</h1>
<p>Per-mod texture packs from the chrome foundry (promo/chrome_foundry.py,
chrome-registry.json). Real pixels, extracted from the shipped .pack files.</p>
{"".join(sections)}
{"".join(surfaces)}
"""
    os.makedirs(os.path.dirname(OUT_HTML), exist_ok=True)
    with open(OUT_HTML, "w", encoding="utf-8", newline="\n") as f:
        f.write(html)
    print(f"[review] wrote {OUT_HTML}")

    if "--no-shot" not in sys.argv:
        subprocess.run([sys.executable, os.path.join(HERE, "shoot.py"),
                        OUT_HTML, OUT_PNG, "1500", "2400"], check=True)
        print(f"[review] shot {OUT_PNG}")


if __name__ == "__main__":
    main()
