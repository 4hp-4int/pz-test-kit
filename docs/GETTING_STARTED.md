# Getting Started with PZ Test Kit

This guide walks you through adding offline tests to your PZ mod from scratch. By the end, you'll have tests running in under 30 seconds on every code change — no game launch required.

## Prerequisites

- Python 3.8+ with `pip install lupa`
- Your PZ mod with Lua code in `media/lua/`
- (Optional) Java 25 for the Kahlua runner

## Step 1: Get the Kit

Clone or download pz-test-kit alongside your mod:

```
your-mods/
├── pz-test-kit/          ← this repo
└── YourMod/
    ├── media/
    │   └── lua/
    │       ├── shared/YourMod/Core.lua
    │       ├── client/YourMod/...
    │       └── server/YourMod/...
    ├── tests/
    │   └── test_core.lua     ← you'll create this
    └── run_tests.py          ← you'll create this
```

## Step 2: Write Your First Test

Create `YourMod/tests/test_core.lua`:

```lua
local Assert = PZTestKit.Assert

local tests = {}

-- Test that your mod loaded
tests["mod_loads"] = function()
    return Assert.notNil(YourMod, "YourMod namespace exists")
end

-- Test a function
tests["validates_weapon"] = function()
    local weapon = instanceItem("Base.Axe")
    if not Assert.notNil(weapon, "spawn Axe") then return false end

    local result = YourMod.isValidWeapon(weapon)
    return Assert.isTrue(result, "Axe is valid weapon")
end

return tests
```

**Key points:**
- Each test is a function in a table
- Return `true` for pass, `false` for fail
- Use `Assert.*` methods — they auto-generate descriptive messages
- `instanceItem("Base.Axe")` creates a mock weapon with real stats

## Step 3: Write the Runner

Create `YourMod/run_tests.py`:

```python
import sys
from pathlib import Path

# Point to wherever you cloned pz-test-kit
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "pz-test-kit" / "lib"))
from pz_test_runner import PZTestRunner

# Weapon stats your tests need (see "Weapon Data" section below)
WEAPONS = {
    "Base.Axe": {
        "minDamage": 0.8, "maxDamage": 2.0, "criticalChance": 20.0,
        "critDmgMultiplier": 5.0, "maxRange": 1.2, "baseSpeed": 1.0,
        "conditionMax": 13, "conditionLowerChance": 35,
        "pushBackMod": 0.3, "maxHitCount": 2,
        "_isRanged": False, "_name": "Axe",
        "_hasSharpness": True, "_hasHeadCondition": True,
        "_headConditionMax": 13,
    },
}

runner = PZTestRunner(mod_root=Path(__file__).parent)
runner.add_weapon_scripts(WEAPONS)

# Load your mod's Lua files in dependency order
runner.load_module("media/lua/shared/YourMod/Core.lua")

# Run all test files in tests/
sys.exit(runner.run())
```

## Step 4: Run It

```bash
cd YourMod
python run_tests.py
```

```
[PZTestKit] Mock environment loaded
[YourMod] Core loaded

--- test_core.lua (2 tests) ---
  [PASS] mod_loads
  [PASS] validates_weapon

TOTAL: 2 tests, 2 passed, 0 failed, 0 errors
```

That's it. Under 1 second, no game launch.

---

## Understanding the Mock Environment

When your test runs, the mock environment provides everything PZ's Lua layer normally provides. Here's what's available and how it works:

### Weapons and Items

```lua
-- Spawn a weapon (uses the stats you provided in WEAPONS dict)
local weapon = instanceItem("Base.Axe")

-- All the getters/setters work like in-game
weapon:getMaxDamage()        -- returns 2.0
weapon:setMaxDamage(3.0)     -- stores the value
weapon:getMaxDamage()        -- returns 3.0

-- ModData works too
local md = weapon:getModData()
md.myField = "hello"
print(md.myField)            -- "hello"

-- Type checking works
instanceof(weapon, "HandWeapon")  -- true
weapon:isRanged()                 -- false (it's an Axe)
```

The mock faithfully reproduces PZ's sharpness behavior (verified from decompiled Java source):
- `getMinDamage()` returns raw value — no sharpness
- `getMaxDamage()` applies sharpness only to the delta above min
- `getCriticalChance()` multiplied by sharpness
- `getCriticalDamageMultiplier()` multiplied by sharpness multiplier

### Player

```lua
local player = getSpecificPlayer(0)

-- Inventory
player:getInventory():AddItem(weapon)
player:setPrimaryHandItem(weapon)
player:getPrimaryHandItem()  -- returns the weapon

-- ModData (persists within a test)
player:getModData().myKey = "value"

-- Player info
player:getPlayerNum()    -- 0
player:getUsername()     -- "TestPlayer"
player:hasTrait("Lucky") -- false (override in your test if needed)
```

### Globals

```lua
-- All of these work as expected:
instanceof(obj, "HandWeapon")     -- checks obj._type field
ZombRand(1, 10)                   -- returns 5 (deterministic midpoint)
getText("UI_MyKey")               -- returns "UI_MyKey" (identity function)
isServer()                        -- false
isClient()                        -- true
sendServerCommand(...)            -- no-op
syncItemModData(...)              -- no-op
```

### Events

```lua
-- Events auto-create and support Add/Remove
Events.OnWeaponSwing.Add(function(player, weapon)
    -- your handler
end)
Events.OnWeaponSwing.Remove(myHandler)
```

### Game Time

```lua
-- Controllable via globals:
_pz_world_hours = 500.0   -- world age in hours
_pz_hour_of_day = 22      -- current hour (0-23)

GameTime.getInstance():getWorldAgeHours()  -- returns 500.0
GameTime.getInstance():getHour()           -- returns 22
```

### Sandbox Variables

```python
# In your runner:
runner.set_sandbox_vars("YourMod", {
    "EnableFeature": True,
    "DamageMultiplier": 1.5,
    "KillThreshold": 50,
})
```

```lua
-- In your Lua code:
SandboxVars.YourMod.EnableFeature     -- true
SandboxVars.YourMod.DamageMultiplier  -- 1.5
```

---

## Weapon Data

### Option A: Hardcode what you need

If your mod only touches a few weapons, just define them in Python:

```python
WEAPONS = {
    "Base.Axe": {"minDamage": 0.8, "maxDamage": 2.0, ...},
    "Base.Pistol": {"minDamage": 0.6, "maxDamage": 1.0, "_isRanged": True, ...},
}
runner.add_weapon_scripts(WEAPONS)
```

### Option B: Parse from PZ scripts

Use the included script parser to read actual game data:

```python
sys.path.insert(0, str(Path("path/to/pz-test-kit/lib")))
from pz_script_parser import parse_weapon_scripts

weapons = parse_weapon_scripts([
    Path("C:/Program Files (x86)/Steam/steamapps/common/ProjectZomboid/media/scripts/generated/items/weapon.txt")
])
runner.add_weapon_scripts(weapons)
```

This gives you all 409 vanilla weapons with correct stats. For CI (no PZ install), save the output as JSON:

```python
import json
with open("weapon_fixtures.json", "w") as f:
    json.dump(weapons, f, indent=2)
```

### Stat field reference

| Python Key | Lua Getter | Type | Notes |
|-----------|-----------|------|-------|
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

## Assert Library Reference

All methods return `true` on pass, `false` on fail, and print a descriptive message.

```lua
local Assert = PZTestKit.Assert

-- Equality
Assert.equal(actual, expected, "label")        -- exact ==
Assert.notEqual(actual, unexpected, "label")   -- exact ~=
Assert.nearEqual(actual, expected, 0.01, "label") -- |a-e| <= tolerance

-- Comparison
Assert.greater(actual, threshold, "label")     -- >
Assert.greaterEq(actual, threshold, "label")   -- >=
Assert.less(actual, threshold, "label")        -- <
Assert.lessEq(actual, threshold, "label")      -- <=

-- Nil / Boolean
Assert.notNil(value, "label")
Assert.isNil(value, "label")
Assert.isTrue(value, "label")     -- strict: must be boolean true
Assert.isFalse(value, "label")    -- strict: must be boolean false

-- Tables
Assert.tableHas(tbl, key, "label")
Assert.tableNotHas(tbl, key, "label")
```

**Pattern: early-return on failure**

```lua
tests["multi_step_test"] = function()
    local weapon = instanceItem("Base.Axe")
    if not Assert.notNil(weapon, "spawn") then return false end

    local data = getModData(weapon)
    if not Assert.notNil(data, "moddata") then return false end

    return Assert.equal(data.kills, 0, "fresh weapon has 0 kills")
end
```

---

## Loading Your Mod's Files

The runner strips `require()` calls and context guards automatically:

```python
# These are stripped:
#   require "YourMod/Core"           → commented out
#   if isServer() then return end    → commented out

runner.load_module("media/lua/shared/YourMod/Core.lua")
runner.load_module("media/lua/shared/YourMod/WeaponSystem.lua")
runner.load_module("media/lua/shared/YourMod/BuffManager.lua")
```

**Load order matters** — load dependencies before the files that use them, just like PZ does.

If your files use `require` with assignment (`local X = require "Mod/Module"`), you can set up a custom require map:

```python
# In the Lua environment after loading mocks:
runner.lua.execute('''
    -- Make require resolve to already-loaded globals
    function require(path)
        if path == "YourMod/Core" then return YourMod end
        return nil
    end
''')
```

---

## CI Integration

### GitHub Actions (Python/lupa)

```yaml
name: Tests
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: '3.11' }
      - run: pip install lupa
      - run: python run_tests.py
```

### GitHub Actions (Kahlua — PZ's actual VM)

```yaml
  test-kahlua:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with: { distribution: 'temurin', java-version: '25' }
      - working-directory: path/to/kahlua
        run: |
          javac -cp kahlua-runtime.jar TestPlatform.java YourKahluaRunner.java
          java -cp kahlua-runtime.jar:. YourKahluaRunner /path/to/mod
```

---

## Tips

**Start small.** Add tests for the functions that have burned you before. The mod function that calculates damage wrong every other release? Test that first.

**Test the logic, not the plumbing.** You don't need to test that `sendServerCommand` fires — that's PZ's job. Test that your code *calls* it with the right arguments, or test the logic that runs before/after.

**Use `_pz_world_hours` and `_pz_hour_of_day`** to control time in tests. But remember: these only work in the offline mock. In-game, `GameTime` is the real Java object. If your test depends on specific time values, guard it:

```lua
local function isOffline()
    return _pz_world_hours ~= nil
end

tests["night_detection"] = function()
    if not isOffline() then return true end  -- skip in-game
    _pz_hour_of_day = 2
    return Assert.isTrue(MyMod.isNight(), "2am is night")
end
```

**Fresh state per test.** The runner resets the mock player (hands, inventory, ModData) between tests. If your mod stores state on custom globals, reset them yourself at the start of each test.

**When a test fails in-game but passes offline**, the mock is wrong about something. That's valuable — it means you found a behavioral difference between your mock and the real game. Fix the mock, fix the test, and you've prevented a whole class of bugs.
