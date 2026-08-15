#!/usr/bin/env bash
# UIView — golden display-list snapshot regression.
#
#   ./snapshot.sh            # compare every emitted scene to its golden; fail on drift
#   ./snapshot.sh --update   # (re)write all goldens from the current render
#
# Runs the Kahlua harness once, extracts every @@UIVIEW_BEGIN:<scene>@@ block,
# and diffs each against tests/__snapshots__/<scene>.json. The display list is
# deterministic, so any diff is a real layout change — intended ones get
# blessed with --update, accidental ones fail CI.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
SNAPDIR="$HERE/tests/__snapshots__"
mkdir -p "$SNAPDIR"

UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

RAW="$(cd "$HERE" && bash "$KIT/pztest" --verbose 2>/dev/null || true)"

names="$(printf '%s\n' "$RAW" \
  | grep -oE '@@UIVIEW_BEGIN:[A-Za-z0-9_-]+@@' \
  | sed -E 's/@@UIVIEW_BEGIN:(.*)@@/\1/' | sort -u)"

if [ -z "$names" ]; then
  echo "[snapshot] no scene blocks emitted — harness output tail:" >&2
  printf '%s\n' "$RAW" | tail -15 >&2
  exit 1
fi

fail=0 n_ok=0 n_new=0 n_drift=0
for s in $names; do
  block="$(printf '%s\n' "$RAW" | awk -v s="$s" '
    $0 ~ ("@@UIVIEW_BEGIN:" s "@@") { g=1; next }
    $0 ~ ("@@UIVIEW_END:" s "@@")   { g=0 }
    g')"
  golden="$SNAPDIR/$s.json"

  if [ "$UPDATE" = "1" ]; then
    printf '%s\n' "$block" > "$golden"
    echo "updated  $s"
    continue
  fi

  if [ ! -f "$golden" ]; then
    echo "NEW      $s  (no golden — run ./snapshot.sh --update to bless)"
    n_new=$((n_new + 1)); fail=1; continue
  fi

  if diff -q <(printf '%s\n' "$block") "$golden" >/dev/null 2>&1; then
    echo "ok       $s"
    n_ok=$((n_ok + 1))
  else
    echo "DRIFT    $s  (layout changed — review, then --update if intended)"
    # show a compact hint of what moved (ops count + first differing chars)
    local_old="$(wc -c < "$golden" | tr -d ' ')"
    local_new="$(printf '%s' "$block" | wc -c | tr -d ' ')"
    echo "           bytes: golden=$local_old current=$local_new"
    n_drift=$((n_drift + 1)); fail=1
  fi
done

if [ "$UPDATE" = "1" ]; then
  echo "[snapshot] goldens updated."
  exit 0
fi

echo "[snapshot] $n_ok ok, $n_drift drift, $n_new new"
exit $fail
