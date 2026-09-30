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
    # PZ's REAL .txt script parser, for scriptcheck (see ScriptCheck.java).
    # Same principle as shipping the real Kahlua VM instead of a Lua-alike: a
    # reimplementation would agree with the engine right up to the moment it
    # mattered. The closure is tiny -- ScriptParser pulls only ScriptBucket,
    # and StringUtils (above) was already here for Kahlua.
    "zombie/scripting/ScriptParser",
    "zombie/scripting/ScriptBucket",
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


# Where the stub Core reads the installed game's version from (see stubs/zombie/
# core/Core.java). Baked rather than hardcoded in the stub so it is re-derived on
# every patch refresh instead of silently going stale.
VERSION_RESOURCE = "zombie/core/pz-game-version.txt"


def find_javap() -> str | None:
    """javap from JAVA_HOME, then PATH. Used to read the game version."""
    java_home = os.environ.get("JAVA_HOME")
    if java_home:
        for name in ("javap.exe", "javap"):
            p = Path(java_home) / "bin" / name
            if p.exists():
                return str(p)
    found = shutil.which("javap")
    if found:
        return found
    # Windows installs land here and often do not export JAVA_HOME.
    candidates = sorted(Path("C:/Program Files/Java").glob("jdk-*/bin/javap.exe"), reverse=True)
    return str(candidates[0]) if candidates else None


def read_game_version(pz_jar: Path) -> str | None:
    """Read Core's GameVersion constant out of the real jar's bytecode.

    Core's <clinit> builds it inline, so the two ints are bipush operands rather
    than constant-pool entries -- there is nothing to grep for in the raw class.
    Disassembling is the cheap way in, and anchoring on the putstatic to
    `gameVersion` keeps it honest if TIS ever adds a second GameVersion literal.
    """
    javap = find_javap()
    if not javap:
        return None
    try:
        out = subprocess.run(
            [javap, "-p", "-c", "-cp", str(pz_jar), "zombie.core.Core"],
            capture_output=True, text=True, timeout=120,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None

    # The sequence is: new GameVersion / dup / push major / push minor / ldc
    # suffix / invokespecial <init> / putstatic gameVersion. Scan line-wise from
    # the putstatic back to its own `new` rather than regexing across the whole
    # disassembly -- Core mints a SECOND GameVersion in getBreakModGameVersion()
    # (42, 0, ""), and a span-matching regex happily reads that one's operands
    # instead, which is how this first reported 42.0 on a 42.21 install.
    lines = out.splitlines()
    end = next(
        (i for i, ln in enumerate(lines)
         if "putstatic" in ln and "Field gameVersion:Lzombie/core/GameVersion;" in ln),
        None,
    )
    if end is None:
        return None
    start = next(
        (i for i in range(end - 1, -1, -1)
         if "new" in lines[i] and "class zombie/core/GameVersion" in lines[i]),
        None,
    )
    if start is None:
        return None

    pushes = re.findall(
        r"\b(?:bipush|sipush)\s+(\d+)\b|\biconst_(\d+)\b",
        "\n".join(lines[start:end]),
    )
    nums = [int(wide or narrow) for wide, narrow in pushes]
    if len(nums) < 2:
        return None
    return f"{nums[0]}.{nums[1]}"


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

    # The installed game's version, for the Core stub to report (see above).
    game_version = read_game_version(pz_jar)
    if game_version:
        print(f"Game version: {game_version} (read from Core.class)")
    else:
        print("WARNING: could not read the game version from Core.class. The Core")
        print("         stub will report 42.0, which makes ZomboidFileSystem skip")
        print("         every versioned mod dir. Check that a JDK's javap is on")
        print("         PATH or JAVA_HOME, then rebuild.")

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

            if game_version:
                zout.writestr(VERSION_RESOURCE, game_version + "\n")

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
