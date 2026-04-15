# PZ Test Kit

Offline test framework for Project Zomboid Build 42 mods. Run your mod's Lua tests in seconds without launching the game — **on PZ's actual Kahlua Lua VM**.

Not a simulation. Not a different Lua implementation. The same `se.krka.kahlua` bytecode interpreter that runs inside the game, extracted into a 613KB self-contained jar.

## Why This Exists

PZ doesn't use standard Lua or LuaJIT. It uses **Kahlua** — a custom Lua 5.1 interpreter written in Java, patched by The Indie Stone. String patterns, number coercion, metatable behavior, pcall semantics — all of these can differ between Kahlua and any standard Lua you test against. If you're testing your mod against LuaJIT or standard Lua 5.1, you're testing against *a different language runtime* than the game uses.

PZ Test Kit gives you:
- **PZ's actual Lua VM** in a 613KB jar — no game install needed
- **Mock PZ API** — player, weapons (60+ getters/setters), items, inventory, events, sandbox vars, GameTime
- **Assert library** — `equal`, `nearEqual`, `greater`, `notNil`, `isTrue`, etc. with auto-generated failure messages
- **Script parser** — reads weapon stats from PZ's actual `.txt` script files

## Quick Start

### Prerequisites

- Java 17+ (`java -version` to check)
- Your PZ mod with Lua code in `media/lua/`

### 1. Clone the kit

```bash
git clone https://github.com/4hp-4int/pz-test-kit.git
```

### 2. Write a test

Create `YourMod/tests/test_core.lua`:

```lua
local Assert = PZTestKit.Assert

local tests = {}

tests["weapon_validates"] = function()
    local weapon = instanceItem("Base.Axe")
    if not Assert.notNil(weapon, "spawn Axe") then return false end
    return Assert.isTrue(YourMod.isValidWeapon(weapon), "Axe is valid")
end

tests["buff_at_100_kills"] = function()
    return Assert.equal(YourMod.getBuffAmount(100), 0.5, "100 kills = 0.5")
end

return tests
```

### 3. Add weapon data

Create `YourMod/weapon_scripts.lua` with the weapons your tests need:

```lua
_pz_weapon_scripts["Base.Axe"] = {
    minDamage = 0.8, maxDamage = 2.0, criticalChance = 20.0,
    critDmgMultiplier = 5.0, maxRange = 1.2, baseSpeed = 1.0,
    conditionMax = 13, conditionLowerChance = 35,
    pushBackMod = 0.3, maxHitCount = 2,
    _isRanged = false, _name = "Axe", _displayName = "Axe",
    _hasSharpness = true, _hasHeadCondition = true, _headConditionMax = 13,
}

_pz_weapon_scripts["Base.Pistol"] = {
    minDamage = 0.6, maxDamage = 1.0, hitChance = 50,
    recoilDelay = 12, clipSize = 15, maxAmmo = 15,
    conditionMax = 10, _isRanged = true, _name = "Pistol",
}
```

Or use the included script parser to read from PZ's actual game files (see [Weapon Data](#weapon-data) below).

### 4. Compile and run

```bash
cd pz-test-kit/kahlua
javac -cp kahlua-runtime.jar TestPlatform.java KahluaTestRunner.java
java -cp kahlua-runtime.jar:. KahluaTestRunner /path/to/YourMod \
    media/lua/shared/YourMod/Core.lua \
    -- tests/test_core.lua
```

On Windows use `;` instead of `:` for the classpath:
```cmd
java -cp kahlua-runtime.jar;. KahluaTestRunner C:\path\to\YourMod ^
    media/lua/shared/YourMod/Core.lua ^
    -- tests/test_core.lua
```

Output:

```
====================================================
PZ Test Kit — Kahlua Runner (PZ's actual Lua VM)
====================================================
Mod root:  C:\path\to\YourMod
Modules:   1
Tests:     1

--- tests/test_core.lua (10 tests) ---

====================================================
KAHLUA TOTAL: 10 tests, 10 passed, 0 failed, 0 errors
====================================================
```

That's it. Your mod's Lua running on PZ's actual VM, in under a second.

### Auto-discovery

If you don't specify test files after `--`, the runner auto-discovers all `tests/test_*.lua` files:

```bash
java -cp kahlua-runtime.jar:. KahluaTestRunner /path/to/YourMod \
    media/lua/shared/YourMod/Core.lua
```

## How It Works

### The Kahlua Runtime Jar

PZ ships `projectzomboid.jar` (~40MB) containing the entire game. Inside it, `se/krka/kahlua/` is the Kahlua Lua VM — an open-source (Apache 2.0) Lua 5.1 implementation in Java.

We extract the VM classes and package them with 3 stub classes that disable PZ's debug assertions:

```java
// zombie/core/Core.java — disables debug checks in KahluaTableImpl.rawset()
public class Core { public static boolean debug = false; }
```

TIS patched `KahluaTableImpl.rawset()` to check `Core.debug` on every Lua table write. Without the stub, this pulls in PZ's entire debug infrastructure. Setting `debug = false` short-circuits the check.

Result: **613KB jar** that runs PZ's Lua VM standalone. No rendering, no networking, no world simulation. Just the bytecode interpreter.

### The Mock Layer

Mocks replace the **data source**, not the **runtime**. Instead of spawning a real `HandWeapon` Java object in a loaded world, we create a Lua table with the same getter/setter interface:

```lua
local weapon = instanceItem("Base.Axe")
weapon:setMaxDamage(2.5)
weapon:getMaxDamage()    -- 2.5
weapon:getModData().foo = "bar"
instanceof(weapon, "HandWeapon")  -- true
```

From Lua's perspective, this is indistinguishable from the real Java object. The Lua code calls the same methods, gets the same types back. The difference is that `getMaxDamage()` reads from a Lua table field instead of a Java field — but the *Lua VM behavior* (how it resolves the call, handles the return value, does arithmetic with it) is identical because it IS the same VM.

### Sharpness Fidelity

The weapon mock matches PZ's actual Java implementation (verified from decompiled `HandWeapon.java`):

- `getMinDamage()` → returns raw value, NO sharpness adjustment
- `getMaxDamage()` → `minDmg + (maxDmg - minDmg) * sharpnessMultiplier` (only the delta)
- `getCriticalChance()` → `raw * sharpness`
- `getCriticalDamageMultiplier()` → `raw * sharpnessMultiplier`
- `getDoorDamage()` / `getTreeDamage()` → `floor(raw * sharpnessMultiplier)`, min 1

Where `sharpnessMultiplier = (sharpness + 1.0) / 2.0`

## What's Mocked

| API | Methods |
|-----|---------|
| **Player** | `getInventory`, `getPrimaryHandItem`, `getModData`, `getPlayerNum`, `hasTrait`, `getUsername`, `getBodyDamage` |
| **HandWeapon** | 60+ getter/setter pairs — damage, crit, condition, sharpness, range, speed, recoil, clip, ammo, fire starting, sound, knockdown, door/tree damage |
| **InventoryItem** | `getFullType`, `getID`, `getModData`, `getMaxAmmo`, `getClipSize`, `getName`, `getScriptItem` |
| **Inventory** | `AddItem`, `removeAllItems`, `containsTypeRecurse`, `getItems` |
| **Globals** | `instanceof`, `ZombRand`, `getText`, `getDebug`, `isServer`, `isClient`, `sendServerCommand`, `syncItemModData`, `getFileWriter`, `table.wipe` |
| **Events** | Auto-creating event tables with `Add`/`Remove` |
| **GameTime** | `getInstance().getWorldAgeHours()`, `getHour()` — controllable via `_pz_world_hours` / `_pz_hour_of_day` globals |
| **SandboxVars** | Set directly: `SandboxVars.YourMod = { Setting = value }` |

### Adding Your Own Mocks

It's just Lua tables. Add methods to the player, create new item types, whatever your mod needs:

```lua
-- In weapon_scripts.lua or a setup file loaded before tests:
_pz_player.getUsername = function(self) return "MyTestPlayer" end
_pz_player.hasTrait = function(self, trait) return trait == "Lucky" end

_pz_item_scripts["MyMod.CustomItem"] = {
    maxAmmo = 10, _name = "Custom Thing",
}
```

## Weapon Data

### Option A: Define in weapon_scripts.lua

```lua
_pz_weapon_scripts["Base.Axe"] = {
    minDamage = 0.8, maxDamage = 2.0, criticalChance = 20.0,
    conditionMax = 13, _isRanged = false, _name = "Axe",
    _hasSharpness = true,
}
```

### Option B: Parse from PZ script files

```python
# Requires Python: pip install lupa (for the parser, not for running tests)
from pz_script_parser import parse_weapon_scripts
from pathlib import Path

weapons = parse_weapon_scripts([
    Path("C:/Program Files (x86)/Steam/steamapps/common/ProjectZomboid/media/scripts/generated/items/weapon.txt")
])
# Generates all 409 vanilla weapons with correct stats
```

Save as JSON for CI, or generate `weapon_scripts.lua` from it.

## Assert Library

All methods return `true` on pass, `false` on fail, and print a descriptive message.

```lua
local Assert = PZTestKit.Assert

Assert.equal(actual, expected, "label")
Assert.notEqual(actual, unexpected, "label")
Assert.nearEqual(actual, expected, 0.01, "label")

Assert.greater(actual, threshold, "label")
Assert.greaterEq(actual, threshold, "label")
Assert.less(actual, threshold, "label")
Assert.lessEq(actual, threshold, "label")

Assert.notNil(value, "label")
Assert.isNil(value, "label")
Assert.isTrue(value, "label")
Assert.isFalse(value, "label")

Assert.tableHas(tbl, key, "label")
Assert.tableNotHas(tbl, key, "label")
```

**Pattern: early-return on failure**

```lua
tests["multi_step"] = function()
    local weapon = instanceItem("Base.Axe")
    if not Assert.notNil(weapon, "spawn") then return false end
    if not Assert.equal(weapon:getConditionMax(), 13, "condMax") then return false end
    return Assert.isTrue(weapon:hasSharpness(), "sharpenable")
end
```

## CI Integration

```yaml
name: Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with: { distribution: 'temurin', java-version: '25' }
      - name: Compile test runner
        working-directory: path/to/pz-test-kit/kahlua
        run: javac -cp kahlua-runtime.jar TestPlatform.java KahluaTestRunner.java
      - name: Run tests on PZ's Kahlua VM
        working-directory: path/to/pz-test-kit/kahlua
        run: java -cp kahlua-runtime.jar:. KahluaTestRunner /path/to/YourMod media/lua/shared/YourMod/Core.lua
```

No PZ install. No Steam auth. Just Java + the 613KB jar.

## Building the Runtime Jar

The repo ships a pre-built `kahlua-runtime.jar`. To rebuild from your own PZ install:

```bash
cd kahlua
python build_runtime_jar.py
```

Auto-discovers your PZ Steam install. Override with `--pz-dir` or `PZ_INSTALL_DIR` env var. See [Getting Started](docs/GETTING_STARTED.md) for the full build explanation.

## Project Structure

```
pz-test-kit/
├── kahlua/
│   ├── kahlua-runtime.jar      # 613KB — PZ's Kahlua VM, self-contained
│   ├── KahluaTestRunner.java   # Generic test runner for any mod
│   ├── TestPlatform.java       # Minimal Platform impl (no PZ game deps)
│   ├── build_runtime_jar.py    # Rebuild jar from your PZ install
│   ├── stdlib.lua              # Kahlua standard library (from PZ)
│   ├── serialize.lua           # Kahlua serialization lib (from PZ)
│   └── stubs/                  # 3 Java stubs that make standalone Kahlua work
├── lua/
│   ├── mock_environment.lua    # PZ API mocks (player, weapons, globals)
│   └── Assert.lua              # Assertion library
├── lib/
│   ├── pz_test_runner.py       # Python/lupa runner (alternative if no Java)
│   └── pz_script_parser.py     # PZ script file parser
├── docs/
│   └── GETTING_STARTED.md      # Detailed walkthrough with examples
├── examples/
│   └── MyMod/                  # Working example: 10 tests, both runners
└── README.md
```

## License

Mock environment, test runner, Assert library, and script parser are MIT licensed.

`kahlua-runtime.jar` contains Kahlua (Apache 2.0) plus minimal stubs. No game assets, game logic, or copyrightable creative content.

## Credits

Built by [Dark Sauce](https://github.com/4hp-4int) for the PZ modding community.

Powered by [Kahlua](https://github.com/krka/kahlua2) — the Lua VM that powers Project Zomboid.
