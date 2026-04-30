# Getting Started with PZ Test Kit

Step-by-step guide to adding offline tests to your PZ mod. By the end you'll have tests running on PZ's actual Lua VM in under a second.

If you're an advanced user, you probably want [the README](../README.md) for the "why" and [PATTERNS.md](PATTERNS.md) for case studies. This doc is the beginner path.

## Prerequisites

- Java 17+ (Java 25 recommended — matches PZ B42's class-file version)
- Your PZ mod with Lua in `media/lua/`
- (Optional) A local PZ install if you want `vanilla_requires`

## Step 1: Install the kit

```bash
git clone https://github.com/4hp-4int/pz-test-kit.git ~/code/pz-test-kit
```

Add the kit's root to your `PATH` so `pztest` is callable from anywhere:

```bash
# Linux / macOS / git-bash
export PATH="$HOME/code/pz-test-kit:$PATH"
chmod +x ~/code/pz-test-kit/pztest
```

Windows PowerShell (add to `$PROFILE`):

```powershell
$env:Path += ";C:\code\pz-test-kit"
```

Verify:

```bash
pztest --help   # or just `pztest` from any directory
```

## Step 2: Project layout

```
YourMod/
├── pz-test.lua                        # (optional) kit config
├── media/
│   ├── lua/
│   │   ├── shared/YourMod/Core.lua
│   │   ├── client/YourMod/SomeThing.lua
│   │   └── client/YourMod/Tests/      # tests auto-discovered here
│   │       └── OfflineCoreTests.lua
│   ├── sandbox-options.txt            # sandbox defaults auto-discovered
│   └── scripts/ ...
```

Auto-discovery looks for test files matching:
- `<ModRoot>/tests/test_*.lua`
- `media/lua/client/<ModName>/Tests/test_*.lua`
- `media/lua/client/<ModName>/Tests/*Tests.lua`

## Step 3: Add `pz-test.lua` (optional but recommended)

Drop this at your mod root. Every key is optional — the kit runs fine without it.

```lua
return {
    -- Modules to require() before each test file.
    -- Usually your mod's Core + any top-level modules tests rely on.
    preload = {
        "YourMod/Core",
    },

    -- SandboxVars defaults. Auto-discovered from
    -- media/sandbox-options.txt when present; this lets you override.
    sandbox = {
        YourMod = {
            EnableMod = true,
            CapacityMultiplier = 100,
        },
    },

    -- (Optional) Load real vanilla PZ files. If your mod hooks/wraps
    -- a vanilla function, include the vanilla file here so your tests
    -- run against the actual implementation. See docs/VANILLA_REQUIRES.md.
    vanilla_requires = {
        "shared/ISBaseObject",
        "shared/TimedActions/ISBaseTimedAction",
    },

    -- (Optional) Exclude in-game-only test files from offline runs.
    -- These usually touch real world state (getCell(), instanceItem for
    -- real Java items) and can't run in the offline harness.
    test_file_excludes = {
        "VisualTests.lua",
        "WorldSpawningTests.lua",
    },

    -- (Optional) Cross-mod dependencies (sibling directories). Each
    -- dependency's media/lua/ tree gets indexed so `require "OtherMod/X"`
    -- works from your tests.
    dependencies = {
        "../TooltipLib",
    },

    -- (Optional) Extra Lua files to load (e.g., generated weapon scripts).
    -- Default: <modRoot>/weapon_scripts.lua if present.
    -- extra_scripts = { "tools/test/items.lua" },
}
```

## Step 4: Write your first test

Create `media/lua/client/YourMod/Tests/OfflineCoreTests.lua`:

```lua
-- Context guards: file runs only in client context, and only under PZTestKit.
if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

require "YourMod/Core"

local tests = {}

tests["mod_namespace_loaded"] = function()
    return Assert.notNil(YourMod, "YourMod global is defined")
end

tests["version_is_a_string"] = function()
    return Assert.equal(type(YourMod.VERSION), "string", "VERSION is a string")
end

return tests
```

**Key rules:**

- Each test is a function on the `tests` table
- Return `true` for pass, `false` for fail
- Use `Assert.*` for auto-generated pass/fail messages
- `return tests` at the end — the runner reads this table

## Step 5: Run your tests

From your mod root:

```bash
pztest
```

Output:

```
====================================================
PZ Test Kit — Kahlua Runner (PZ's actual Lua VM)
====================================================
Mod root:         /path/to/YourMod
Indexed modules:  12
Test files:       1

[PZTestKit] Mock environment loaded
[PZTestKit] Assert library loaded
[PZTestKit] require resolver installed (12 modules indexed)
[PZTestKit] Applied sandbox defaults for 1 mod(s)
[PZTestKit] Preloaded 1 module(s) from config

  [PASS] YourMod global is defined: not nil
  [PASS] VERSION is a string: "string" == "string"

--- media/lua/client/YourMod/Tests/OfflineCoreTests.lua (2 tests, 8ms) ---

====================================================
KAHLUA TOTAL: 2 tests, 2 passed, 0 failed, 0 errors (312ms)
====================================================
```

Options:

| Flag | Purpose |
|---|---|
| `pztest` (no args) | Auto-discover and run all tests in current directory |
| `pztest /path/to/mod` | Run against a specific mod root |
| `pztest --filter substring` | Only run tests whose name contains `substring` |
| `pztest path/to/single_file.lua` | Single test file |
| `pztest --junit-xml results.xml` | Emit JUnit XML for CI |

## Step 6: Write tests for the thing that keeps breaking

Start with the function that's burned you in the past. Not the pretty well-tested one — the one that snuck through into production and caused a Workshop report.

If your mod ships MP features, look at the [duplication vector cheat sheet](FIXTURES.md#appendix--counter-cheat-sheet) and pick an assertion. If you can name a real regression and write the one-line counter assertion for it, you've got your second test.

See [PATTERNS.md](PATTERNS.md) for case studies from shipped mods.

## Assert library reference

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

Each assertion returns true/false, so you can short-circuit and get a clear failure at the step that broke.

## Fixtures — the interesting stuff

`PZTestKit.Fixtures` is where the real value lives for advanced mods. It gives you Lua-table stand-ins for PZ's Java-backed objects, each with counters on every mutating method.

```lua
local F = PZTestKit.Fixtures

-- Create a faithful mock player with a mock inventory
local player = F.player()

-- Create a mock cart container with capacity 100
local cart = F.container({ capacity = 100, typeName = "ShoppingCart" })

-- Create a mock world square
local sq = F.square(10, 10, 0)

-- Full world fixture: auto-wires getCell(), network spy, event spy
local world = F.world()
local sq = world:square(0, 0, 0)
local p  = world:player({ square = sq })
-- ... do stuff ...
local count = world.network:count("sendAddItemToContainer")
world:teardown()
```

Full API reference in [FIXTURES.md](FIXTURES.md).

## Skip tests that don't apply in this environment

Some tests only make sense offline (they synthesize a fake `ISHandcraftAction`, etc.). Some only make sense in-game (they need real world state). Mark them skipped instead of pretending success:

```lua
tests["offline_only_synthetic_test"] = function()
    if _pz_module_sources == nil then
        return PZTestKit.skip("runs only under pz-test-kit")
    end
    return realTest()
end
```

Or the convenience gate at registration time:

```lua
PZTestKit.skipInGame(TestRunner, "my_offline_test", function()
    -- body runs only under pz-test-kit, skipped when running in real PZ
end)
```

Skipped tests surface as `<skipped>` in JUnit XML. They don't fail the suite.

## CI integration

### Option 1: composite action (simplest)

```yaml
# .github/workflows/test.yml
name: Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: 4hp-4int/pz-test-kit@main
        with:
          mod-root: ${{ github.workspace }}
          junit-xml: pz-test-results.xml
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: pz-test-results
          path: pz-test-results.xml
      # Optional: publish test results to PR
      - uses: dorny/test-reporter@v1
        if: success() || failure()
        with:
          name: PZ Tests
          path: pz-test-results.xml
          reporter: java-junit
```

### Option 2: manual setup (pins a kit version)

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with: { distribution: 'temurin', java-version: '25' }
      - run: |
          git clone --depth 1 --branch main \
            https://github.com/4hp-4int/pz-test-kit.git "$RUNNER_TEMP/pz-test-kit"
          cd "$RUNNER_TEMP/pz-test-kit/kahlua"
          javac -cp kahlua-runtime.jar \
            TestPlatform.java KahluaTestRunner.java DualVMSim.java \
            StubbingClassLoader.java PZTestKitLauncher.java
      - run: |
          chmod +x "$RUNNER_TEMP/pz-test-kit/pztest"
          "$RUNNER_TEMP/pz-test-kit/pztest" "$GITHUB_WORKSPACE" \
            --junit-xml pz-test-results.xml
```

### CI caveat: vanilla_requires

If your `pz-test.lua` lists `vanilla_requires`, your CI runner probably doesn't have PZ installed. The kit falls back to mocks and logs a warning — tests still run, you just lose vanilla-drift detection. See [VANILLA_REQUIRES.md](VANILLA_REQUIRES.md) for workarounds (staging vanilla files in your repo, installing PZ via SteamCMD).

## Weapon / item data

If your mod touches weapons, add `weapon_scripts.lua` at your mod root:

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

Or generate from PZ's actual game files:

```bash
python ~/code/pz-test-kit/tools/pz_script_parser.py --lua > weapon_scripts.lua
python ~/code/pz-test-kit/tools/pz_script_parser.py --lua --filter "Base.Axe,Base.Pistol" > weapon_scripts.lua
```

`instanceItem(fullType)` will then return a weapon mock with those stats.

## The mock environment (high-level)

`mock_environment.lua` provides PZ's Lua API surface. Some highlights:

- **Player:** `getSpecificPlayer(0)`, `:getInventory()`, `:setPrimaryHandItem()`, `:hasTrait()`, `:getStats()`, `:getXp()`, traits via `player._traits`
- **Weapons:** `instanceItem("Base.Axe")` returns a mock with all getters/setters, sharpness math, condition, etc.
- **Events:** `Events.OnWeaponSwing.Add(fn)` — auto-creates any event name on first access
- **SandboxVars:** `SandboxVars.YourMod.X` with defaults from `sandbox-options.txt` or your `pz-test.lua`
- **GameTime:** controllable globals `_pz_world_hours`, `_pz_hour_of_day`
- **Weather:** `_pz_rain_intensity` / `getWorld():getClimateManager()`
- **Network:** `sendServerCommand()` / `syncItemModData()` etc. are stubs (no-op by default; patched by `Fixtures.networkSpy` when you want to capture)

If your test hits `attempt to call nil`, you're calling a PZ method that isn't mocked. Either add a one-liner to your test setup or a mock to `mock_environment.lua` (contributions welcome).

## Tips

**Start with the thing that keeps breaking.** Not the most interesting function. The one whose bug reports you remember.

**Test logic, not plumbing.** Don't test that `sendServerCommand` fires — test the state before and after. Use `Fixtures.networkSpy` to assert the call count is what you expected.

**Counters > return values.** "Did it succeed?" is table stakes. "Did it fire exactly once?" is the assertion that survives PZ refactors.

**When a test passes offline but fails in-game**, your mock is wrong about something. That's valuable — fix the mock and you prevent a whole class of bugs.

**When a test fails with `attempt to call nil`**, you're calling a PZ method that isn't mocked yet. Add it to your test setup — it's one line.

**Reset state between tests.** The runner resets player hands/inventory/ModData between tests, but if your mod uses custom globals or patches globals (via `Fixtures.*spy:install()`), restore them yourself (via `:teardown()`).

## Next steps

- Skim [FIXTURES.md](FIXTURES.md) for the mock API + counter cheat sheet
- Read [PATTERNS.md](PATTERNS.md) for case studies from shipped mods
- If you hook vanilla PZ code: [VANILLA_REQUIRES.md](VANILLA_REQUIRES.md)
- Open an issue if you find a PZ API that isn't mocked — usually a one-line fix
