# PZ Test Kit

Offline test framework for Project Zomboid Build 42 mods. Run your mod's Lua tests in seconds without launching the game — on the **exact same Lua VM** PZ uses.

## What This Is

- **Mock PZ API**: Player, weapons, items, inventory, events, sandbox vars, GameTime — all mocked as Lua tables with the same method signatures the game exposes
- **Assert library**: `equal`, `nearEqual`, `greater`, `notNil`, `isTrue`, etc. with auto-generated failure messages
- **Two test runners**:
  - **Python/lupa** (LuaJIT) — fast, great for CI
  - **Java/Kahlua** (PZ's actual Lua VM) — catches Kahlua-specific behavior differences
- **Script parser**: Reads weapon stats from PZ's `.txt` script files so your mocks match real game data
- **610KB self-contained Kahlua jar** — no PZ install needed, no Steam auth

## Quick Start

### 1. Install

```bash
pip install lupa
```

### 2. Write a test

```lua
-- tests/test_mymod.lua
local Assert = PZTestKit.Assert

local tests = {}

tests["my_weapon_check"] = function()
    local weapon = instanceItem("Base.Axe")
    if not Assert.notNil(weapon, "spawn Axe") then return false end
    return Assert.isTrue(MyMod.isValidWeapon(weapon), "Axe is valid")
end

tests["my_buff_calculation"] = function()
    return Assert.equal(MyMod.getBuffAmount(100), 0.5, "100 kills = 0.5 buff")
end

return tests
```

### 3. Write a runner

```python
# run_tests.py
import sys
from pathlib import Path

sys.path.insert(0, str(Path("path/to/pz-test-kit/lib")))
from pz_test_runner import PZTestRunner

WEAPONS = {
    "Base.Axe": {
        "minDamage": 0.8, "maxDamage": 2.0, "criticalChance": 20.0,
        "conditionMax": 13, "_isRanged": False, "_name": "Axe",
        "_hasSharpness": True, "_headConditionMax": 13,
        "_hasHeadCondition": True,
    },
}

runner = PZTestRunner(mod_root=".")
runner.add_weapon_scripts(WEAPONS)
runner.load_module("media/lua/shared/MyMod/Core.lua")
sys.exit(runner.run())
```

### 4. Run

```bash
python run_tests.py
```

```
[PZTestKit] Mock environment loaded
[MyMod] Core loaded v1.0.0

--- test_mymod.lua (2 tests) ---
  [PASS] my_weapon_check
  [PASS] my_buff_calculation

TOTAL: 2 tests, 2 passed, 0 failed, 0 errors
```

## Building the Kahlua Runtime Jar

The repo ships a pre-built `kahlua-runtime.jar`, but you can rebuild it from your own PZ install. This extracts the Kahlua Lua VM classes from `projectzomboid.jar`, resolves PZ dependencies, and bakes in the debug stubs.

### Automatic (recommended)

```bash
cd kahlua
python build_runtime_jar.py
```

It auto-discovers your PZ Steam install. Override with:

```bash
python build_runtime_jar.py --pz-dir "D:/Steam/steamapps/common/ProjectZomboid"
# or
PZ_INSTALL_DIR="/path/to/ProjectZomboid" python build_runtime_jar.py
```

This also copies `stdlib.lua` and `serialize.lua` from your PZ install (required by Kahlua's standard library).

### What the build does

1. Opens `projectzomboid.jar` (~40MB) from your PZ install
2. Extracts all `se/krka/kahlua/` and `org/luaj/kahluafork/` classes (the Lua VM + compiler)
3. Resolves transitive PZ class dependencies (BoxedStaticValues, DebugLog, ConfigOption, etc.)
4. Removes `DebugOptions` and `Core` classes (replaced by our stubs)
5. Bakes in 3 stub classes that disable PZ's debug assertions in `KahluaTableImpl.rawset()`
6. Outputs a ~610KB self-contained jar

### Why stubs are needed

TIS patched `KahluaTableImpl.rawset()` to check `zombie.core.Core.debug` and `zombie.debug.DebugOptions` on every Lua table write. Without stubs, this pulls in PZ's debug infrastructure → config system → rendering → LWJGL → half the game. The stubs set `Core.debug = false` which short-circuits all debug checks (the real code does `if (Core.debug) { ... }`).

### Manual build (if you want to understand it)

```bash
# 1. Extract Kahlua classes
python -c "
import zipfile
with zipfile.ZipFile('path/to/projectzomboid.jar') as z:
    for name in z.namelist():
        if name.startswith('se/krka/kahlua/') or name.startswith('org/luaj/kahluafork/'):
            z.extract(name, 'extracted/')
"

# 2. Compile stubs
javac stubs/zombie/core/Core.java
javac stubs/zombie/debug/BooleanDebugOption.java
javac stubs/zombie/debug/DebugOptions.java

# 3. Package (stubs + extracted classes)
jar cf kahlua-runtime.jar -C stubs . -C extracted .

# 4. Run, hit NoClassDefFoundError, add missing class, repeat until clean
```

Step 4 is what `build_runtime_jar.py` automates — it iteratively scans bytecode for `zombie/` class references and pulls them in.

## Kahlua Runner (PZ's Actual Lua VM)

The Kahlua runner uses PZ's actual `se.krka.kahlua` Lua interpreter — the same bytecode VM that runs in-game. This catches Kahlua-specific behavior that LuaJIT might miss (string patterns, number coercion, metatable edge cases).

```bash
cd kahlua
javac -cp kahlua-runtime.jar TestPlatform.java YourTestRunner.java
java -cp kahlua-runtime.jar:. YourTestRunner /path/to/your/mod
```

The `kahlua-runtime.jar` (610KB) contains:
- Kahlua VM + compiler (`se.krka.kahlua.*`)
- LuaJ compiler fork (`org.luaj.kahluafork.*`)
- Minimal PZ stubs (3 classes) to satisfy KahluaTableImpl's debug assertions

No game assets, no rendering, no networking. Just the Lua runtime.

## What's Mocked

| API | Methods |
|-----|---------|
| **Player** | `getInventory`, `getPrimaryHandItem`, `getModData`, `getPlayerNum`, `hasTrait`, `getUsername`, `getBodyDamage` |
| **HandWeapon** | 60+ getter/setter pairs — damage, crit, condition, sharpness, range, speed, recoil, clip, ammo, fire starting, sound, knockdown, door/tree damage |
| **InventoryItem** | `getFullType`, `getID`, `getModData`, `getMaxAmmo`, `getClipSize`, `getName`, `getScriptItem` |
| **Inventory** | `AddItem`, `removeAllItems`, `containsTypeRecurse`, `getItems` |
| **Globals** | `instanceof`, `ZombRand`, `getText`, `getDebug`, `isServer`, `isClient`, `sendServerCommand`, `syncItemModData`, `getFileWriter` |
| **Events** | Auto-creating event tables with `Add`/`Remove` |
| **GameTime** | `getInstance().getWorldAgeHours()`, `getHour()` — controllable via `_pz_world_hours` / `_pz_hour_of_day` globals |
| **SandboxVars** | Settable per-mod via `runner.set_sandbox_vars("MyMod", {...})` |

### Sharpness Fidelity

The weapon mock matches PZ's actual Java implementation (verified from decompiled `HandWeapon.java`):

- `getMinDamage()` → returns raw value, NO sharpness adjustment
- `getMaxDamage()` → `minDmg + (maxDmg - minDmg) * sharpnessMultiplier` (sharpness only affects the delta)
- `getCriticalChance()` → `raw * sharpness`
- `getCriticalDamageMultiplier()` → `raw * sharpnessMultiplier`
- `getDoorDamage()` / `getTreeDamage()` → `floor(raw * sharpnessMultiplier)`, min 1

Where `sharpnessMultiplier = (sharpness + 1.0) / 2.0`

## CI Integration (GitHub Actions)

```yaml
name: Tests
on: [push, pull_request]

jobs:
  test-lupa:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: '3.11' }
      - run: pip install lupa
      - run: python run_tests.py

  test-kahlua:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with: { distribution: 'temurin', java-version: '25' }
      - run: javac -cp kahlua/kahlua-runtime.jar kahlua/TestPlatform.java kahlua/YourRunner.java
      - run: java -cp kahlua/kahlua-runtime.jar:kahlua YourRunner .
```

## Script Parser

Parse weapon stats from PZ's actual `.txt` script files instead of hardcoding values:

```python
from pz_script_parser import parse_weapon_scripts
from pathlib import Path

weapons = parse_weapon_scripts([
    Path("C:/Program Files (x86)/Steam/steamapps/common/ProjectZomboid/media/scripts/generated/items/weapon.txt")
])

# weapons["Base.Axe"] == {"maxDamage": 2.0, "minDamage": 0.8, ...}
```

Falls back to a committed JSON fixture for CI (no PZ install).

## Project Structure

```
pz-test-kit/
├── lua/
│   ├── mock_environment.lua    # PZ API mocks (player, weapons, globals)
│   └── Assert.lua              # Assertion library
├── kahlua/
│   ├── kahlua-runtime.jar      # 610KB standalone Kahlua VM
│   ├── TestPlatform.java       # Minimal Platform (no PZ game deps)
│   ├── stdlib.lua              # Kahlua standard library
│   └── serialize.lua           # Kahlua serialization
├── lib/
│   ├── pz_test_runner.py       # Python/lupa test runner
│   └── pz_script_parser.py     # PZ script file parser
├── examples/
│   └── MyMod/                  # Example mod with 10 passing tests
└── README.md
```

## License

The mock environment, test runner, Assert library, and script parser are MIT licensed.

The `kahlua-runtime.jar` contains Kahlua (Apache 2.0) plus minimal PZ debug stubs. It contains no game assets, game logic, or copyrightable creative content.

## Credits

Built by [Dark Sauce](https://github.com/4hp-4int) for the PZ modding community.
