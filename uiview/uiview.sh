#!/usr/bin/env bash
# UIView — render a PZ panel headlessly and build a browser preview.
#
#   ./uiview.sh [scene] [--open]
#     scene  : which emitted scene to view (default: palette).
#              known: demo (weapon tooltip), palette (SaucePalette)
#     --open : open the result in the default browser
#
# Runs the pz-test-kit Kahlua harness, captures the @@UIVIEW_BEGIN:<scene>@@
# JSON block, and inlines it into viewer.template.html so the result is a
# single self-contained file (no server / no CORS).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/out"
mkdir -p "$OUT"

SCENE="palette"
OPEN=0
for a in "$@"; do
  case "$a" in
    --open) OPEN=1 ;;
    -*)     ;;
    *)      SCENE="$a" ;;
  esac
done

ROOTS=("$KIT/../sauce-shortorder" "$KIT/../sauce-invrender" "$KIT/../SauceCanonical" "$KIT/../PZ-TooltipLib" "$KIT/../SauceTooltips" "$KIT/../VorpallySauced")

# Texture sizes BEFORE the harness runs: UIMock's getTexture reads the
# generated table, and any code that tiles or fits by source size needs the
# real numbers to behave the way it does in game. Regenerated every run --
# a stale table is worse than an obviously missing one, and this is only a few
# ms of .pack header parsing.
python "$HERE/tools/gen_texture_sizes.py" "${ROOTS[@]}" 2>/dev/null >&2 \
  || echo "[uiview] warning: texture sizes not regenerated (using committed table)" >&2

echo "[uiview] rendering scene '$SCENE' via Kahlua harness..." >&2
RAW="$(cd "$HERE" && bash "$KIT/pztest" --verbose 2>/dev/null || true)"

# Extract the JSON between the named sentinels.
JSON="$(printf '%s\n' "$RAW" | awk -v s="$SCENE" '
  $0 ~ ("@@UIVIEW_BEGIN:" s "@@") { grab=1; next }
  $0 ~ ("@@UIVIEW_END:" s "@@")   { grab=0 }
  grab { print }
')"

if [ -z "$JSON" ]; then
  echo "[uiview] ERROR: no UIVIEW JSON captured. Harness output:" >&2
  printf '%s\n' "$RAW" | tail -20 >&2
  exit 1
fi

# The "ad" scene is a multi-frame storyboard (for the player), not a single
# frame (for the viewer). Pick template + output + json filename accordingly.
if [ "$SCENE" = "ad" ]; then
  TEMPLATE="$HERE/player.template.html"
  JSONOUT="$OUT/storyboard.json"
  HTMLOUT="$OUT/player.html"
elif [ "$SCENE" = "states" ]; then
  TEMPLATE="$HERE/contact.template.html"
  JSONOUT="$OUT/states.json"
  HTMLOUT="$OUT/contact.html"
else
  TEMPLATE="$HERE/viewer.template.html"
  JSONOUT="$OUT/scene.json"
  HTMLOUT="$OUT/view.html"
fi

printf '%s\n' "$JSON" > "$JSONOUT"

# Inline replay core + base64 icons + frame/storyboard JSON into a self-contained shell.
python "$HERE/build_view.py" \
  --template "$TEMPLATE" \
  --json "$JSONOUT" \
  --replay "$HERE/replay.js" \
  --out "$HTMLOUT" \
  --roots "${ROOTS[@]}"

echo "$HTMLOUT"

if [ "$OPEN" = "1" ]; then
  start "" "$(cygpath -w "$OUT/view.html" 2>/dev/null || echo "$OUT/view.html")" 2>/dev/null \
    || cmd.exe /c start "" "$(cygpath -w "$OUT/view.html")" 2>/dev/null || true
fi
