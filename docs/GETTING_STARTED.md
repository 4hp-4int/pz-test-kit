# Getting Started with PZ Test Kit

This guide walks you through adding offline tests to your PZ mod. By the end, you'll have tests running on PZ's actual Lua VM in under a second — no game launch required.

## Prerequisites

- Java 17+ (`java -version` — Java 25 recommended to match PZ B42)
- Your PZ mod with Lua code in `media/lua/`
- (Optional) Python 3 for the weapon script parser

## Step 1: Get the Kit

Clone pz-test-kit alongside your mod:

```
your-mods/
├── pz-test-kit/
└── YourMod/
    ├── media/lua/shared/YourMod/Core.lua
    ├── tests/
    │   └── test_core.lua
    └── weapon_scripts.lua
```

## Step 2: Add Weapon Data

If your mod touches weapons, create `YourMod/weapon_scripts.lua` with the weapons your tests need:

```lua
_pz_weapon_scripts["Base.Axe"] = {
    minDamage = 0.8, maxDamage = 2.0, criticalChance = 20.0,
    critDmgMultiplier = 5.0, maxRange = 1.2, baseSpeed = 1.0,
    conditionMax = 13, conditionLowerChance = 35,
    pushBackMod = 0.3, maxHitCount = 2,
    _isRanged = false, _name = "Axe", _displayName = "Axe",
    _hasSharpness = true, _hasHeadCondition = true, _headConditionMax = 13,
}
```

Or generate it from PZ's actual game files (real stats, not guesswork):

```bash
python pz-test-kit/tools/pz_script_parser.py --lua > weapon_scripts.lua

# Only specific weapons:
python pz-test-kit/tools/pz_script_parser.py --lua --filter "Base.Axe,Base.Pistol" > weapon_scripts.lua
```

If your mod doesn't touch weapons, skip this — the mock environment works without weapon data.

## Step 3: Write a Test

Create `YourMod/tests/test_core.lua`:

```lua
local Assert = PZTestKit.Assert

local tests = {}

tests["mod_loads"] = function()
    return Assert.notNil(YourMod, "YourMod namespace exists")
end

tests["validates_weapon"] = function()
    local weapon = instanceItem("Base.Axe")
    if not Assert.notNil(weapon, "spawn Axe") then return false end
    return Assert.isTrue(YourMod.isValidWeapon(weapon), "Axe is valid")
end

tests["buff_calculation"] = function()
    return Assert.equal(YourMod.getBuffAmount(100), 0.5, "100 kills = 0.5")
end

return tests
```

**Key points:**
- Each test is a function in a table
- Return `true` for pass, `false` for fail
- Use `Assert.*` for auto-generated pass/fail messages
- `return tests` at the end — the runner reads this table

## Step 4: Compile and Run

```bash
cd pz-test-kit/kahlua

# Compile (one time)
javac -cp kahlua-runtime.jar TestPlatform.java KahluaTestRunner.java

# Run your tests
java -cp kahlua-runtime.jar:. KahluaTestRunner /path/to/YourMod \
    media/lua/shared/YourMod/Core.lua
```

On Windows use `;` instead of `:`:
```cmd
java -cp kahlua-runtime.jar;. KahluaTestRunner C:\path\to\YourMod ^
    media/lua/shared/YourMod/Core.lua
```

Output:
```
====================================================
PZ Test Kit — Kahlua Runner (PZ's actual Lua VM)
====================================================
Mod root:  C:\path\to\YourMod
Modules:   1
Tests:     1

--- test_core.lua (3 tests) ---

====================================================
KAHLUA TOTAL: 3 tests, 3 passed, 0 failed, 0 errors
====================================================
```

Under a second. No game launch.

---

## How the Runner Works

The runner has four parts, each a separate file you can read and modify:

| File | What it does |
|------|-------------|
| `KahluaTestRunner.java` | CLI, creates a fresh Kahlua runtime per test file, loads mocks → modules → tests, collects results |
| `TestPlatform.java` | Minimal Kahlua Platform implementation — no PZ game dependencies |
| `mock_environment.lua` | All the PZ API mocks — player, weapons, inventory, events, time, globals |
| `test_executor.lua` | Runs each test function with state reset between tests, collects pass/fail/error |
| `Assert.lua` | Assertion library with auto-generated messages |

**Per-file isolation:** Each test file gets its own fresh Kahlua runtime. Test file A can't leak state into test file B. Within a file, `test_executor.lua` resets the player (hands, inventory, ModData, traits) between each test.

**Module loading:** The runner strips `require()` calls and context guards (`if isServer() then return end`) automatically. Load your files in dependency order — just like PZ does.

---

## The Mock Environment

When your test runs, `mock_environment.lua` provides everything PZ's Lua layer normally provides.

### Weapons and Items

```lua
-- Spawn a weapon (stats from weapon_scripts.lua)
local weapon = instanceItem("Base.Axe")
weapon:getMaxDamage()          -- 2.0 (from script data)
weapon:setMaxDamage(3.0)
weapon:getMaxDamage()          -- 3.0
weapon:getModData().myField = "hello"
instanceof(weapon, "HandWeapon")  -- true
weapon:isRanged()                 -- false
```

The weapon mock faithfully reproduces PZ's sharpness behavior (verified from decompiled `HandWeapon.java`):

```lua
weapon:setSharpness(0.5)
-- getMinDamage()  → raw value (no sharpness adjustment)
-- getMaxDamage()  → minDmg + (maxDmg - minDmg) * sharpnessMult
-- getCriticalChance() → raw * sharpness
```

### Player

```lua
local player = getSpecificPlayer(0)

-- Inventory
player:getInventory():AddItem(weapon)
player:setPrimaryHandItem(weapon)
player:getPrimaryHandItem()     -- the weapon

-- ModData
player:getModData().myKey = "value"

-- Info
player:getUsername()             -- "TestPlayer"
player:getPlayerNum()           -- 0
instanceof(player, "IsoPlayer") -- true

-- Traits (configurable per test)
player._traits["Lucky"] = true
player:hasTrait("Lucky")        -- true
player._traits = {}             -- reset

-- Stats (matches real PZ API: get/set with CharacterStat enum)
local stats = player:getStats()
stats:get(CharacterStat.ENDURANCE)              -- 1.0
stats:set(CharacterStat.ENDURANCE, 0.5)
stats:remove(CharacterStat.ENDURANCE, 0.1)      -- subtract

-- Skills
local xp = player:getXp()
xp:setLevel("Aiming", 5)
xp:getLevel("Aiming")          -- 5
xp:getLevel("Carpentry")       -- 0 (default)

-- Position / indoors
player._isOutside = true
player:getCurrentSquare():isOutside()  -- true
player._isOutside = false              -- reset
```

### Zombies

```lua
local zombie = _pz_create_mock_zombie({ health = 2.5 })
zombie:getHealth()               -- 2.5
zombie:setStaggerBack(true)
zombie:isStaggerBack()           -- true
zombie:SetOnFire()
zombie:isOnFire()                -- true
instanceof(zombie, "IsoZombie")  -- true
```

### World / Weather

```lua
local world = getWorld()
local cm = world:getClimateManager()
cm:getRainIntensity()           -- 0.0 (default)
cm:getTemperature()             -- 20.0 (default)

-- Control in tests:
_pz_rain_intensity = 0.8
cm:getRainIntensity()           -- 0.8
_pz_rain_intensity = 0.0       -- reset
```

### Grid Squares

```lua
local sq = _pz_create_mock_square({ isOutside = true, x = 100, y = 200 })
sq:isOutside()    -- true
sq:getRoom()      -- nil (outside)
sq:getX()         -- 100

local indoor = _pz_create_mock_square({ isOutside = false, room = "bedroom" })
indoor:getRoom():getName()  -- "bedroom"
```

### Game Time

```lua
-- Controllable globals:
_pz_world_hours = 500.0
_pz_hour_of_day = 3             -- 3am

GameTime.getInstance():getWorldAgeHours()  -- 500.0
GameTime.getInstance():getHour()           -- 3

-- Reset after test:
_pz_world_hours = 100.0
_pz_hour_of_day = 14
```

### Events

```lua
Events.OnWeaponSwing.Add(function(player, weapon)
    -- your handler gets registered
end)
Events.OnWeaponSwing.Remove(handler)
-- Auto-creates any event name on first access
```

### Sandbox Variables

```lua
SandboxVars.YourMod = {
    EnableFeature = true,
    DamageMultiplier = 1.5,
    KillThreshold = 50,
}
SandboxVars.YourMod.EnableFeature  -- true
```

### Globals

```lua
instanceof(obj, "HandWeapon")         -- checks obj._type
ZombRand(0, 10)                       -- 5 (deterministic midpoint)
getText("UI_MyKey")                   -- "UI_MyKey" (identity)
isServer()                            -- false
isClient()                            -- true
sendServerCommand(...)                -- no-op (safe)
syncItemModData(...)                  -- no-op
```

---

## Building Your Own Mocks

Every PZ Java class is just a Lua table with methods. Mock what your code calls:

```lua
-- IsoZombie: your mod calls getHealth() and setStaggerBack()
function _pz_create_mock_zombie(opts)
    opts = opts or {}
    local z = { _type = "IsoZombie", _health = opts.health or 1.8 }
    z.getHealth = function(self) return self._health end
    z.setStaggerBack = function(self, v) self._staggerBack = v end
    return z
end
```

When a test fails with `attempt to call nil`, that tells you which method to add — one line.

See the README for examples of mocking `IsoGridSquare`, `IsoWorld`, weather, and vehicles.

---

## Assert Library

```lua
local Assert = PZTestKit.Assert

-- Equality
Assert.equal(actual, expected, "label")
Assert.notEqual(actual, unexpected, "label")
Assert.nearEqual(actual, expected, 0.01, "label")

-- Comparison
Assert.greater(actual, threshold, "label")
Assert.greaterEq(actual, threshold, "label")
Assert.less(actual, threshold, "label")
Assert.lessEq(actual, threshold, "label")

-- Nil / Boolean
Assert.notNil(value, "label")
Assert.isNil(value, "label")
Assert.isTrue(value, "label")
Assert.isFalse(value, "label")

-- Tables
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

---

## Loading Your Mod's Files

Pass module paths as arguments before `--`:

```bash
java -cp kahlua-runtime.jar:. KahluaTestRunner /path/to/YourMod \
    media/lua/shared/YourMod/Core.lua \
    media/lua/shared/YourMod/Combat.lua \
    media/lua/shared/YourMod/Buffs.lua \
    -- tests/test_core.lua tests/test_combat.lua
```

**Load order matters** — list dependencies before the files that use them.

The runner strips `require()` and context guards automatically. If your code uses `local X = require "Mod/Module"`, that becomes `local X = nil`. Your module should already be loaded as a global by the time it's referenced.

If you omit test files after `--`, the runner auto-discovers all `tests/test_*.lua` files.

---

## CI Integration (GitHub Actions)

```yaml
name: Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: true  # if pz-test-kit is a submodule

      - uses: actions/setup-java@v4
        with: { distribution: 'temurin', java-version: '25' }

      - name: Compile
        working-directory: pz-test-kit/kahlua
        run: javac -cp kahlua-runtime.jar TestPlatform.java KahluaTestRunner.java

      - name: Run tests on PZ's Kahlua VM
        working-directory: pz-test-kit/kahlua
        run: java -cp kahlua-runtime.jar:. KahluaTestRunner ../../ media/lua/shared/YourMod/Core.lua
```

No PZ install. No Steam auth. Just Java + the 613KB jar.

---

## Weapon Data Reference

| Lua Key | Getter | Type | Notes |
|---------|--------|------|-------|
| `minDamage` | `getMinDamage()` | float | No sharpness adjustment |
| `maxDamage` | `getMaxDamage()` | float | Sharpness affects delta only |
| `criticalChance` | `getCriticalChance()` | float | × sharpness |
| `critDmgMultiplier` | `getCriticalDamageMultiplier()` | float | × sharpnessMult |
| `maxRange` | `getMaxRange()` | float | |
| `baseSpeed` | `getBaseSpeed()` | float | |
| `conditionMax` | `getConditionMax()` | int | |
| `conditionLowerChance` | `getConditionLowerChance()` | int | Higher = less degradation |
| `pushBackMod` | `getPushBackMod()` | float | |
| `maxHitCount` | `getMaxHitCount()` | int | |
| `hitChance` | `getHitChance()` | int | Firearms |
| `recoilDelay` | `getRecoilDelay()` | int | Firearms |
| `clipSize` | `getClipSize()` | int | Firearms |
| `maxAmmo` | `getMaxAmmo()` | int | Firearms |
| `_isRanged` | `isRanged()` | bool | **Required** for firearms |
| `_name` | `getName()` | string | Display name |
| `_hasSharpness` | `hasSharpness()` | bool | Bladed weapons |
| `_hasHeadCondition` | `hasHeadCondition()` | bool | Axes |
| `_headConditionMax` | `getHeadConditionMax()` | int | If hasHeadCondition |
| `_magazineType` | `getMagazineType()` | string | Detachable mag weapons |

---

## Tips

**Start small.** Test the function that keeps breaking first.

**Test logic, not plumbing.** Don't test that `sendServerCommand` fires — test the logic before and after it.

**When a test passes offline but fails in-game**, the mock is wrong about something. That's valuable — fix the mock and you've prevented a whole class of bugs.

**When a test fails with `attempt to call nil`**, you're calling a PZ method that isn't mocked yet. Add it to `mock_environment.lua` — it's one line.

**Reset state in tests that modify globals.** The runner resets the player between tests, but if your mod uses custom globals, reset them yourself:

```lua
tests["my_test"] = function()
    local saved = SandboxVars.MyMod.Setting
    SandboxVars.MyMod.Setting = 999
    -- ... test ...
    SandboxVars.MyMod.Setting = saved
    return Assert.isTrue(result, "worked")
end
```
