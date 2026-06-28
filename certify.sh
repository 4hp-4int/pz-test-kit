#!/usr/bin/env bash
# certify.sh — validate the test suite against the INSTALLED PrZ build.
#
# A green suite only proves the mod matches the mocks. This also reads the live
# Steam buildid and compares it to the certified one in CERTIFICATION.md, so a
# vanilla API drift (especially the Build 43 line) doesn't hide behind green tests.
#
#   ./certify.sh                 # default: scope "palette", run from uiview/
#   ./certify.sh <scope> <dir>   # other mods: coverage scope + the dir to run pztest in
#
# See CERTIFICATION.md for the B42-stable / B43-divergence model.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOPE="${1:-palette}"
TESTDIR="${2:-$SCRIPT_DIR/uiview}"
APPMANIFEST="/c/Program Files (x86)/Steam/steamapps/appmanifest_108600.acf"

say() { printf '%s\n' "$*"; }
hr()  { say "------------------------------------------------------------"; }

# --- live Steam build of PZ (appid 108600) -----------------------------------
LIVE_BUILD=""
if [ -f "$APPMANIFEST" ]; then
    LIVE_BUILD="$(grep -oE '"buildid"[[:space:]]+"[0-9]+"' "$APPMANIFEST" | grep -oE '[0-9]+' | head -1)"
fi

# --- certified build (the backtick-wrapped buildid in CERTIFICATION.md) -------
CERT_BUILD="$(grep -oE '`[0-9]{6,}`' "$SCRIPT_DIR/CERTIFICATION.md" 2>/dev/null | tr -d '`' | head -1)"

hr; say "PZ Test Kit — certification"; hr
say "Scope:            $SCOPE"
say "Certified build:  ${CERT_BUILD:-<none recorded>}"
say "Installed build:  ${LIVE_BUILD:-<could not read appmanifest>}"

# --- run the suite + coverage ------------------------------------------------
hr; say "Running suite + coverage (scope: $SCOPE)..."; hr
OUT="$(cd "$TESTDIR" && bash ../pztest --coverage="$SCOPE" 2>&1)"
TOTAL="$(echo "$OUT" | grep -E 'KAHLUA TOTAL' | tail -1)"
COV="$(echo "$OUT"  | grep -E '^[[:space:]]*TOTAL ' | tail -1)"
say "${TOTAL:-<no KAHLUA TOTAL line — did the run crash?>}"
say "Coverage: ${COV:-<none>}"

PASS=1
echo "$TOTAL" | grep -qE '0 failed, 0 errors' || PASS=0

# --- verdict -----------------------------------------------------------------
hr
if [ "$PASS" -ne 1 ]; then
    say "RESULT: [FAIL] suite has failures/errors — fix before certifying."
    hr; exit 1
fi
if [ -z "$LIVE_BUILD" ]; then
    say "RESULT: [OK] suite green. Could not read the installed build — verify the"
    say "        version manually against CERTIFICATION.md."
elif [ "$LIVE_BUILD" = "$CERT_BUILD" ]; then
    say "RESULT: [CERTIFIED] green against the installed build ($LIVE_BUILD)."
else
    say "RESULT: [DRIFT] suite green, but the install CHANGED."
    say "        certified $CERT_BUILD  ->  installed $LIVE_BUILD"
    say ""
    say "  - Still Build 42 (a 42.x patch)? The vanilla API is locked. Re-stamp:"
    say "    update buildid / coverage / date in CERTIFICATION.md and commit."
    say "  - Build 43 (major jump — check the main-menu version)? STOP. Do not trust"
    say "    this green run; re-derive the mocked vanilla API against the B43 source."
    hr; exit 2
fi
hr
