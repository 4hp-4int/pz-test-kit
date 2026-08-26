#!/usr/bin/env bash
# Deploy the PZShell mod into a PZ Build 42 mods folder.
#
# Mirrors the logic in pz-mods/deploy.ps1's Deploy-Mod: flat source layout
# (mod.info + media/ at the root of ./mod/) gets transformed into the B42
# target structure:
#
#   <target>/PZShell/common/mod.info
#   <target>/PZShell/42.0/media/lua/server/PZShell.lua
#   <target>/PZShell/42.0/poster.<ext>   (if present at source root)
#
# Usage:
#   ./deploy.sh                        deploy to $USERPROFILE/Zomboid/mods/
#   ./deploy.sh /path/to/Zomboid/mods  deploy to an explicit target root

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$script_dir/mod"

default_target="${USERPROFILE:-$HOME}/Zomboid/mods"
target="${1:-$default_target}"
target="${target//\\//}"

[[ -f "$src/mod.info" ]] || { echo "source mod.info not found at $src/mod.info" >&2; exit 1; }
[[ -d "$src/media" ]]    || { echo "source media/ not found at $src/media" >&2; exit 1; }

# Extract mod id from mod.info for the target path.
mod_id=$(grep -E '^id=' "$src/mod.info" | head -n1 | cut -d= -f2- | tr -d '\r')
: "${mod_id:?mod.info has no id= line}"

dst="$target/$mod_id"

# Fresh deploy.
rm -rf "$dst"
mkdir -p "$dst/common" "$dst/42.0"

# mod.info → common/
cp "$src/mod.info" "$dst/common/mod.info"

# media/ → 42.0/media/
cp -r "$src/media" "$dst/42.0/media"

# poster.<ext> → 42.0/ (if present)
for ext in png jpg gif; do
    if [[ -f "$src/poster.$ext" ]]; then
        cp "$src/poster.$ext" "$dst/42.0/poster.$ext"
        break
    fi
done

echo "deployed $mod_id → $dst"

# The agent is what makes `eval` work on 2026-08+ builds (PZ unbound loadstring
# from Lua). Say so at deploy time rather than letting it surface as a baffling
# nil later: ZombieBuddy finds the jar via mod.info's javaJarFile line, and
# ZombieBuddy itself only attaches if the JVM was started with -javaagent.
if [[ -f "$dst/42.0/media/java/shared/PZShellAgent.jar" ]]; then
    echo "  agent: PZShellAgent.jar deployed"
else
    echo "  agent: MISSING — eval will not work on PZ 2026-08+ builds."
    echo "         build it with: (cd agent && ./build.ps1)"
fi

echo
echo "next steps:"
echo "  1. ensure $mod_id is in your servertest.ini Mods= line"
echo "  2. ZombieBuddy must be installed AND the JVM launched with"
echo "     -javaagent:ZombieBuddy.jar (Steam launch options, or vmArgs in"
echo "     ProjectZomboid64.json). Without it the agent never loads."
echo "  3. restart the dedi"
echo "  4. arm the gate:   ./pz-shell enable"
echo "  5. check the agent: ./pz-shell eval 'return PZShell_agentVersion()'"
echo "  6. try a probe:     ./pz-shell eval 'return 1+1'"
