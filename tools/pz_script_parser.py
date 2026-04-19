"""
PZ Script Parser — Parse Project Zomboid .txt script files into weapon stat dicts
================================================================================
Reads PZ's `module/item` script format and extracts weapon stats into the same
dict structure used by pz_test_runner.py's mock weapon factory.

Usage:
    from pz_script_parser import parse_weapon_scripts
    scripts = parse_weapon_scripts([Path("weapon.txt")])
    # scripts["Base.Axe"] == {"maxDamage": 2.0, "minDamage": 0.8, ...}
"""

from __future__ import annotations

import re
from pathlib import Path

# ============================================================================
# Key mapping: PZ script CamelCase → VPS mock camelCase
# ============================================================================

# (script_key, mock_key, type_coerce)
# type_coerce: "float", "int", "bool", "str"
STAT_KEY_MAP = {
    "MaxDamage": ("maxDamage", "float"),
    "MinDamage": ("minDamage", "float"),
    "CriticalChance": ("criticalChance", "float"),
    "CritDmgMultiplier": ("critDmgMultiplier", "float"),
    "MaxRange": ("maxRange", "float"),
    "MinRange": ("minRange", "float"),
    "BaseSpeed": ("baseSpeed", "float"),
    "ConditionMax": ("conditionMax", "int"),
    "ConditionLowerChanceOneIn": ("conditionLowerChance", "int"),
    "PushBackMod": ("pushBackMod", "float"),
    "MaxHitcount": ("maxHitCount", "int"),
    "KnockdownMod": ("knockdownMod", "float"),
    "TreeDamage": ("treeDamage", "int"),
    "DoorDamage": ("doorDamage", "int"),
    "EnduranceMod": ("enduranceMod", "float"),
    "RecoilDelay": ("recoilDelay", "int"),
    "Reloadtime": ("reloadTime", "int"),
    "ClipSize": ("clipSize", "int"),
    "MaxAmmo": ("maxAmmo", "int"),
    "HitChance": ("hitChance", "int"),
    "Aimingtime": ("aimingTime", "int"),
    "JamGunChance": ("jamGunChance", "int"),
    "SoundRadius": ("soundRadius", "int"),
    "NoiseRange": ("noiseRange", "int"),
    "SoundGain": ("soundGain", "float"),
    "Weight": ("_weight", "float"),
    # Private fields from specific keys
    "Ranged": ("_isRanged", "bool"),
    "MagazineType": ("_magazineType", "str"),
    "WeaponReloadType": ("_reloadType", "str"),
    # Sharpness / head condition (used for derived fields)
    "Sharpness": ("_sharpnessRaw", "float"),
    "HeadCondition": ("_headConditionRaw", "int"),
}

# Items that are weapons (have ItemType = base:weapon)
WEAPON_ITEM_TYPE = "base:weapon"


def _coerce(value_str: str, type_name: str):
    """Coerce a string value to the specified type."""
    if type_name == "float":
        return float(value_str)
    elif type_name == "int":
        return int(float(value_str))  # int(float()) handles "2.0" -> 2
    elif type_name == "bool":
        return value_str.lower() == "true"
    else:  # str
        return value_str


def _camel_to_display(name: str) -> str:
    """Convert CamelCase item name to display name. BaseballBat -> Baseball Bat"""
    # Insert space before uppercase letters that follow lowercase
    result = re.sub(r"([a-z])([A-Z])", r"\1 \2", name)
    # Insert space before uppercase letters followed by lowercase (handles acronyms)
    result = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1 \2", result)
    # Handle underscores
    result = result.replace("_", " ")
    return result


def _process_item(module_name: str, item_name: str, raw_props: dict) -> dict | None:
    """Convert raw parsed properties into a VPS mock stat dict. Returns None if not a weapon."""
    # Only process weapon items
    item_type = raw_props.get("ItemType", "").lower()
    if item_type != WEAPON_ITEM_TYPE:
        return None

    stats = {}

    # Map known stat keys
    for script_key, (mock_key, type_name) in STAT_KEY_MAP.items():
        if script_key in raw_props:
            try:
                stats[mock_key] = _coerce(raw_props[script_key], type_name)
            except (ValueError, TypeError):
                pass  # Skip unparseable values

    # Derive _isRanged (default False)
    if "_isRanged" not in stats:
        stats["_isRanged"] = False

    # Derive _name / _displayName from item name
    display = _camel_to_display(item_name)
    stats["_name"] = display
    stats["_displayName"] = display

    # Derive _hasHeadCondition / _headConditionMax
    if "_headConditionRaw" in stats:
        stats["_hasHeadCondition"] = True
        stats["_headConditionMax"] = stats.pop("_headConditionRaw")
    else:
        stats["_hasHeadCondition"] = False

    # Derive _hasSharpness
    if "_sharpnessRaw" in stats:
        stats["_hasSharpness"] = True
        stats.pop("_sharpnessRaw")
    else:
        stats["_hasSharpness"] = False

    # Clean up internal keys
    stats.pop("_weight", None)

    return stats


def parse_weapon_scripts(
    script_paths: list[Path],
    filter_types: set[str] | None = None,
) -> dict[str, dict]:
    """
    Parse PZ script files and return weapon stat dicts.

    Args:
        script_paths: List of .txt script file paths to parse
        filter_types: If provided, only return weapons with these full types (e.g. {"Base.Axe"})

    Returns:
        Dict mapping full type (e.g. "Base.Axe") to stat dict
    """
    weapons = {}

    for path in script_paths:
        if not path.exists():
            continue
        parsed = _parse_file(path)
        weapons.update(parsed)

    # Apply filter
    if filter_types is not None:
        weapons = {k: v for k, v in weapons.items() if k in filter_types}

    return weapons


def _parse_file(path: Path) -> dict[str, dict]:
    """Parse a single script file. Returns dict of full_type -> stat_dict.

    Tracks brace depth to handle nested blocks inside items
    (e.g. `component FluidContainer { ... }` inside Saucepan).
    """
    weapons = {}
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()

    state = "TOPLEVEL"
    module_name = ""
    item_name = ""
    raw_props = {}
    # brace_depth: 0 = toplevel, 1 = in module, 2 = in item, 3+ = nested block
    brace_depth = 0

    for line in lines:
        # Strip comments
        line = line.split("//")[0].strip()
        if not line:
            continue

        # Count braces on this line
        opens = line.count("{")
        closes = line.count("}")

        if state == "TOPLEVEL":
            m = re.match(r"module\s+(\w+)", line)
            if m:
                module_name = m.group(1)
                if opens > 0:
                    state = "IN_MODULE"
                    brace_depth = 1
                else:
                    state = "WAIT_MODULE_BRACE"

        elif state == "WAIT_MODULE_BRACE":
            if opens > 0:
                state = "IN_MODULE"
                brace_depth = 1

        elif state == "IN_MODULE":
            m = re.match(r"item\s+(\w+)", line)
            if m:
                item_name = m.group(1)
                raw_props = {}
                if opens > 0:
                    state = "IN_ITEM"
                    brace_depth = 2
                else:
                    state = "WAIT_ITEM_BRACE"
            elif closes > 0:
                # Module close
                state = "TOPLEVEL"
                brace_depth = 0
            elif re.match(r"imports\s*\{", line):
                pass  # Single-line imports block, ignore

        elif state == "WAIT_ITEM_BRACE":
            if opens > 0:
                state = "IN_ITEM"
                brace_depth = 2

        elif state == "IN_ITEM":
            # Adjust depth for nested blocks (component, attachments, etc.)
            brace_depth += opens - closes

            if brace_depth <= 1:
                # Back to module level — item closed
                brace_depth = 1
                result = _process_item(module_name, item_name, raw_props)
                if result is not None:
                    full_type = f"{module_name}.{item_name}"
                    weapons[full_type] = result
                state = "IN_MODULE"
            elif brace_depth == 2 and opens == 0 and closes == 0:
                # Normal property line at item level
                m = re.match(r"(\w+)\s*=\s*(.+?),?\s*$", line)
                if m:
                    key = m.group(1)
                    value = m.group(2).strip().rstrip(",")
                    raw_props[key] = value
            # depth > 2 or lines with braces in nested blocks: skip

    return weapons


# ============================================================================
# Output generators
# ============================================================================

def to_lua(weapons: dict[str, dict], header: str = "") -> str:
    """Generate a weapon_scripts.lua file from parsed weapon data."""
    lines = [
        "-- Auto-generated from PZ script files by pz_script_parser.py",
        "-- Reload with: python pz_script_parser.py --lua <script_file.txt> > weapon_scripts.lua",
    ]
    if header:
        lines.append(f"-- {header}")
    lines.append("")

    for full_type in sorted(weapons.keys()):
        stats = weapons[full_type]
        lines.append(f'_pz_weapon_scripts["{full_type}"] = {{')
        for k in sorted(stats.keys()):
            v = stats[k]
            if isinstance(v, bool):
                lines.append(f"    {k} = {'true' if v else 'false'},")
            elif isinstance(v, str):
                lines.append(f'    {k} = "{v}",')
            elif isinstance(v, (int, float)):
                lines.append(f"    {k} = {v},")
        lines.append("}")
    lines.append("")
    return "\n".join(lines)


def to_json(weapons: dict[str, dict]) -> str:
    """Generate JSON from parsed weapon data."""
    import json
    return json.dumps(weapons, indent=2, default=str)


# ============================================================================
# CLI
# ============================================================================

if __name__ == "__main__":
    import sys
    import json
    import os

    # Parse args
    output_format = "summary"
    filter_types = None
    script_paths = []

    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--lua":
            output_format = "lua"
        elif args[i] == "--json":
            output_format = "json"
        elif args[i] == "--filter":
            i += 1
            filter_types = set(args[i].split(","))
        elif args[i] in ("-h", "--help"):
            print("Usage: python pz_script_parser.py [--lua|--json] [--filter Type1,Type2] <script_file.txt> [...]")
            print()
            print("  --lua       Output weapon_scripts.lua (for Kahlua test runner)")
            print("  --json      Output JSON (for fixtures or inspection)")
            print("  --filter    Comma-separated list of weapon types to include")
            print()
            print("Examples:")
            print('  python pz_script_parser.py --lua weapon.txt > weapon_scripts.lua')
            print('  python pz_script_parser.py --json --filter "Base.Axe,Base.Pistol" weapon.txt')
            print()
            print("Auto-discovers PZ install if no script file given:")
            print("  python pz_script_parser.py --lua > weapon_scripts.lua")
            sys.exit(0)
        else:
            script_paths.append(Path(args[i]))
        i += 1

    # Auto-discover PZ weapon.txt if no paths given
    if not script_paths:
        candidates = [
            Path("C:/Program Files (x86)/Steam/steamapps/common/ProjectZomboid/media/scripts/generated/items/weapon.txt"),
            Path("C:/Program Files/Steam/steamapps/common/ProjectZomboid/media/scripts/generated/items/weapon.txt"),
            Path(os.path.expanduser("~/.steam/steam/steamapps/common/ProjectZomboid/media/scripts/generated/items/weapon.txt")),
        ]
        env = os.environ.get("PZ_INSTALL_DIR")
        if env:
            candidates.insert(0, Path(env) / "media/scripts/generated/items/weapon.txt")
        for c in candidates:
            if c.exists():
                script_paths.append(c)
                break

    if not script_paths:
        print("ERROR: No script files found. Pass a path or set PZ_INSTALL_DIR.", file=sys.stderr)
        sys.exit(1)

    weapons = parse_weapon_scripts(script_paths, filter_types=filter_types)

    if output_format == "lua":
        print(to_lua(weapons))
    elif output_format == "json":
        print(to_json(weapons))
    else:
        print(f"Parsed {len(weapons)} weapons from {[str(p) for p in script_paths]}:")
        for full_type in sorted(weapons.keys()):
            stats = weapons[full_type]
            ranged = "ranged" if stats.get("_isRanged") else "melee"
            sharp = " sharp" if stats.get("_hasSharpness") else ""
            head = " head" if stats.get("_hasHeadCondition") else ""
            print(f"  {full_type} ({ranged}{sharp}{head})")
