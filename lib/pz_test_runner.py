"""
PZ Test Kit — Generic offline test runner
==========================================
Uses lupa (embedded LuaJIT) to run PZ mod tests with mocked PZ APIs.

Usage from your mod:
    from pz_test_kit import PZTestRunner
    runner = PZTestRunner(mod_root="path/to/YourMod")
    runner.add_weapon_scripts({"Base.Axe": {...}})
    runner.load_module("media/lua/shared/YourMod/Core.lua")
    runner.load_tests("tests/test_core.lua")
    runner.run()
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

try:
    from lupa import LuaRuntime
except ImportError:
    print("ERROR: lupa not installed. Run: pip install lupa")
    sys.exit(1)


KIT_DIR = Path(__file__).parent.parent.resolve()


def load_lua_file(lua, filepath, strip_requires=True, strip_context_guards=True):
    """Load a Lua file, optionally stripping require() and context guards."""
    with open(filepath, "r", encoding="utf-8") as f:
        source = f.read()

    if strip_requires:
        source = re.sub(
            r'(local\s+\w+\s*=\s*)require\s+"([^"]*)"',
            r'\1nil -- [stripped require]',
            source,
        )
        source = re.sub(
            r'^(\s*)require\s+"[^"]*"',
            r'\1-- [stripped require]',
            source,
            flags=re.MULTILINE,
        )

    if strip_context_guards:
        source = re.sub(
            r'if\s+isServer\s*\(\s*\)\s+and\s+not\s+isClient\s*\(\s*\)\s+then\s+return\s+end',
            "-- [stripped context guard]",
            source,
        )
        source = re.sub(
            r'if\s+isClient\s*\(\s*\)\s+then\s+return\s+end',
            "-- [stripped context guard]",
            source,
        )

    try:
        lua.execute(source)
    except Exception as e:
        print(f"  ERROR loading {filepath}: {e}")
        raise


class PZTestRunner:
    def __init__(self, mod_root: str | Path = "."):
        self.mod_root = Path(mod_root).resolve()
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self._load_mock_environment()

    def _load_mock_environment(self):
        """Load the PZ mock environment."""
        mock_path = KIT_DIR / "lua" / "mock_environment.lua"
        load_lua_file(self.lua, mock_path, strip_requires=False, strip_context_guards=False)

        assert_path = KIT_DIR / "lua" / "Assert.lua"
        load_lua_file(self.lua, assert_path, strip_requires=False, strip_context_guards=False)

    def add_weapon_scripts(self, scripts: dict):
        """Add weapon script data to the mock environment."""
        g = self.lua.globals()
        table = g._pz_weapon_scripts
        for full_type, stats in scripts.items():
            lua_stats = self.lua.table_from(
                {k: v for k, v in stats.items() if not k.startswith("_")}
            )
            for k, v in stats.items():
                if k.startswith("_"):
                    lua_stats[k] = v
            table[full_type] = lua_stats

    def add_item_scripts(self, scripts: dict):
        """Add non-weapon item scripts (magazines, etc.)."""
        g = self.lua.globals()
        table = g._pz_item_scripts
        for full_type, stats in scripts.items():
            table[full_type] = self.lua.table_from(stats)

    def set_sandbox_vars(self, mod_name: str, vars: dict):
        """Set SandboxVars for a mod."""
        g = self.lua.globals()
        sv = g.SandboxVars
        sv[mod_name] = self.lua.table_from(vars)

    def load_module(self, relative_path: str, **kwargs):
        """Load a Lua module from the mod root."""
        path = self.mod_root / relative_path
        load_lua_file(self.lua, path, **kwargs)

    def load_tests(self, relative_path: str) -> dict:
        """Load a test file that returns a table of test functions."""
        path = self.mod_root / relative_path
        with open(path, "r", encoding="utf-8") as f:
            source = f.read()

        # Strip requires
        source = re.sub(r'(local\s+\w+\s*=\s*)require\s+"([^"]*)"', r'\1nil', source)
        source = re.sub(r'^(\s*)require\s+"[^"]*"', r'\1-- [stripped]', source, flags=re.MULTILINE)

        result = self.lua.execute(source)
        return result

    def run_test_table(self, tests, file_name: str = "tests") -> tuple[int, int, int, int]:
        """Run a table of test functions. Returns (total, passed, failed, errors)."""
        g = self.lua.globals()
        total = passed = failed = errors = 0

        # Collect and sort test names
        names = []
        for name in tests:
            names.append(name)
        names.sort()

        print(f"\n--- {file_name} ({len(names)} tests) ---")

        for name in names:
            test_fn = tests[name]
            total += 1

            # Reset player state
            g._pz_player._primaryHand = None
            g._pz_player._secondaryHand = None
            g._pz_player_inventory._items = self.lua.table_from({})
            self.lua.execute("_pz_player_moddata = {}")

            try:
                result = test_fn()
                if result:
                    passed += 1
                    print(f"  [PASS] {name}")
                else:
                    failed += 1
                    print(f"  [FAIL] {name}")
            except Exception as e:
                errors += 1
                err_msg = str(e)[:200]
                print(f"  [ERROR] {name} -- {err_msg}")

        return total, passed, failed, errors

    def run(self, test_files: list[str] | None = None):
        """Run all test files and print summary."""
        if test_files is None:
            # Auto-discover test files
            test_dir = self.mod_root / "tests"
            if test_dir.exists():
                test_files = [f"tests/{f.name}" for f in sorted(test_dir.glob("test_*.lua"))]
            else:
                print("ERROR: No test files found")
                return 1

        grand_total = grand_passed = grand_failed = grand_errors = 0

        for tf in test_files:
            tests = self.load_tests(tf)
            if tests:
                total, passed, failed, errors = self.run_test_table(tests, Path(tf).name)
                grand_total += total
                grand_passed += passed
                grand_failed += failed
                grand_errors += errors

        print(f"\n{'=' * 60}")
        print(f"TOTAL: {grand_total} tests, {grand_passed} passed, {grand_failed} failed, {grand_errors} errors")
        print(f"{'=' * 60}")

        return 1 if (grand_failed + grand_errors) > 0 else 0
