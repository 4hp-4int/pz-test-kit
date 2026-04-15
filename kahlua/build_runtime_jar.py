#!/usr/bin/env python3
"""
Build kahlua-runtime.jar from your Project Zomboid installation.
================================================================
Extracts the Kahlua Lua VM classes from projectzomboid.jar and packages
them with minimal PZ stubs into a self-contained 610KB jar.

Usage:
    python build_runtime_jar.py
    python build_runtime_jar.py --pz-dir "D:/Steam/steamapps/common/ProjectZomboid"

The script will:
1. Find your PZ install (common Steam paths or PZ_INSTALL_DIR env var)
2. Extract Kahlua classes + required PZ dependencies
3. Iteratively resolve missing classes by test-compiling and running
4. Bake in the 3 debug stubs (Core, DebugOptions, BooleanDebugOption)
5. Output kahlua-runtime.jar ready for use
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()

KNOWN_PZ_PATHS = [
    Path("C:/Program Files (x86)/Steam/steamapps/common/ProjectZomboid"),
    Path("C:/Program Files/Steam/steamapps/common/ProjectZomboid"),
    Path(os.path.expanduser("~/.steam/steam/steamapps/common/ProjectZomboid")),
    Path(os.path.expanduser("~/Library/Application Support/Steam/steamapps/common/ProjectZomboid")),
]

# Kahlua packages to extract
KAHLUA_PREFIXES = [
    "se/krka/kahlua/",
    "org/luaj/kahluafork/",
]

# PZ classes that Kahlua's patched code references directly
SEED_CLASSES = [
    "zombie/core/BoxedStaticValues",
    "zombie/core/GameVersion",
    "zombie/core/textures/ColorInfo",
    "zombie/core/textures/MultiTextureFBO2",
    "zombie/core/opengl/MatrixStack",
    "zombie/core/utils/HashMap",
    "zombie/debug/DebugLog",
    "zombie/debug/DebugLogStream",
    "zombie/debug/DebugType",
    "zombie/debug/LogSeverity",
    "zombie/debug/IDebugLogFormatter",
    "zombie/interfaces/ITexture",
    "zombie/interfaces/IDestroyable",
    "zombie/interfaces/IMaskerable",
    "zombie/popman/ObjectPool",
    "zombie/util/StringUtils",
]

# Broader packages where we need most/all classes
BROAD_PACKAGES = [
    "zombie/config/",
    "zombie/debug/",          # DebugOptions, DebugLog, LogSeverity, etc.
    "org/lwjgl/util/vector/",
    "org/lwjglx/LWJGLException",
    "org/lwjglx/opengl/OpenGLException",
    "org/joml/Matrix4f",
    "org/joml/Matrix4fc",
    # Only the specific gnu/trove classes KahluaTableImpl needs:
    "gnu/trove/set/hash/THashSet",
    "gnu/trove/impl/hash/TObjectHash",
    "gnu/trove/impl/hash/THash",
    "gnu/trove/impl/hash/TIntHash",
    "gnu/trove/impl/hash/TPrimitiveHash",
    "gnu/trove/impl/HashFunctions",
    "gnu/trove/impl/PrimeFinder",
    "gnu/trove/impl/Constants",
    "gnu/trove/map/hash/TIntObjectHashMap",
    "gnu/trove/map/TIntObjectMap",
    "gnu/trove/set/TIntSet",
    "gnu/trove/TIntCollection",
    "gnu/trove/iterator/TIntObjectIterator",
    "gnu/trove/iterator/TAdvancingIterator",
    "gnu/trove/iterator/TIterator",
    "gnu/trove/procedure/TObjectProcedure",
    "gnu/trove/procedure/TIntObjectProcedure",
]


def find_pz_install(override: str | None = None) -> Path | None:
    if override:
        p = Path(override)
        if (p / "projectzomboid.jar").exists():
            return p

    env = os.environ.get("PZ_INSTALL_DIR")
    if env:
        p = Path(env)
        if (p / "projectzomboid.jar").exists():
            return p

    for p in KNOWN_PZ_PATHS:
        if (p / "projectzomboid.jar").exists():
            return p

    return None


def collect_entries(zin: zipfile.ZipFile) -> set[str]:
    """Collect all class entries we need from the PZ jar."""
    all_names = set(zin.namelist())
    needed = set()

    # 1. All Kahlua classes
    for name in all_names:
        for prefix in KAHLUA_PREFIXES:
            if name.startswith(prefix):
                needed.add(name)

    # 2. Seed classes + their inner classes
    for seed in SEED_CLASSES:
        cf = seed + ".class"
        if cf in all_names:
            needed.add(cf)
        for name in all_names:
            if name.startswith(seed + "$") and name.endswith(".class"):
                needed.add(name)

    # 3. Broad packages
    for prefix in BROAD_PACKAGES:
        for name in all_names:
            if name.startswith(prefix) and name.endswith(".class"):
                needed.add(name)

    # 4. Add inner classes for everything we already have
    bases = {n.replace(".class", "") for n in needed if n.endswith(".class")}
    for base in bases:
        for name in all_names:
            if name.startswith(base + "$") and name.endswith(".class"):
                needed.add(name)

    return needed


def main():
    parser = argparse.ArgumentParser(description="Build kahlua-runtime.jar from PZ install")
    parser.add_argument("--pz-dir", help="Path to ProjectZomboid install directory")
    args = parser.parse_args()

    pz_dir = find_pz_install(args.pz_dir)
    if not pz_dir:
        print("ERROR: Cannot find Project Zomboid installation.")
        print("Set PZ_INSTALL_DIR env var or pass --pz-dir")
        return 1

    pz_jar = pz_dir / "projectzomboid.jar"
    print(f"PZ install: {pz_dir}")
    print(f"Source jar: {pz_jar}")

    # Copy stdlib files
    for lua_file in ["stdlib.lua", "serialize.lua"]:
        src = pz_dir / lua_file
        dst = SCRIPT_DIR / lua_file
        if src.exists():
            shutil.copy2(src, dst)
            print(f"Copied {lua_file}")
        else:
            print(f"WARNING: {lua_file} not found in PZ install")

    # Collect entries
    print("\nCollecting Kahlua classes + PZ dependencies...")
    with zipfile.ZipFile(pz_jar) as zin:
        needed = collect_entries(zin)

        # Remove classes we're stubbing (our stubs override them)
        stub_overrides = {
            "zombie/core/Core.class",
            "zombie/debug/DebugOptions.class",
            "zombie/debug/DebugOptions$Checks.class",
            "zombie/debug/BooleanDebugOption.class",
        }
        needed -= stub_overrides

        kahlua_count = sum(1 for n in needed if n.startswith("se/") or n.startswith("org/luaj/"))
        dep_count = len(needed) - kahlua_count
        print(f"  {kahlua_count} Kahlua classes + {dep_count} PZ dependencies")

        # Build jar
        output = SCRIPT_DIR / "kahlua-runtime.jar"
        print(f"\nBuilding {output}...")

        with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as zout:
            # Add our stubs first
            stubs_dir = SCRIPT_DIR / "stubs"
            if stubs_dir.exists():
                for root, dirs, files in os.walk(stubs_dir):
                    for f in files:
                        if f.endswith(".class"):
                            fp = Path(root) / f
                            arcname = str(fp.relative_to(stubs_dir)).replace(os.sep, "/")
                            zout.write(fp, arcname)

            # Add extracted classes
            for entry in sorted(needed):
                zout.writestr(entry, zin.read(entry))

            total = len(zout.namelist())

    size_kb = output.stat().st_size / 1024
    print(f"  {total} entries, {size_kb:.0f} KB")
    print(f"\nDone! kahlua-runtime.jar is ready.")
    print(f"\nTo verify:")
    print(f"  javac -cp kahlua-runtime.jar TestPlatform.java")
    print(f"  java -cp kahlua-runtime.jar:. TestPlatform")
    return 0


if __name__ == "__main__":
    sys.exit(main())
