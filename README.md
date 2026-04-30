# PZ Test Kit

Offline test framework for Project Zomboid Build 42 mods. Runs your mod's Lua tests in seconds **on PZ's actual Kahlua Lua VM** — not a simulation, not a different implementation. The same `se.krka.kahlua` bytecode interpreter that runs inside the game, extracted into a 613KB self-contained jar.

Built for mods complex enough to have shipped MP bugs to the Workshop.

## Why build this

If you ship an MP-capable PZ mod to the Workshop, you've eaten (or will eat) bugs in this family:

- **Item duplication.** A cart dropped twice because `AddWorldInventoryItem` fires its own broadcast AND your code fires one too, so every client sees two items with the same ID ([SaucedCarts v2.1.4](#)).
- **Container consistency races.** A transfer succeeds on client 1, silently rejects on server, client 2 now has a phantom item that doesn't exist authoritatively.
- **Stale hand refs + forceDropHeavyItems.** `ISEnterVehicle` calls `forceDropHeavyItems` on server, the command handler calls it again, `AddWorldInventoryItem` fires twice with a stale reference. Your cart duplicates ([SaucedCarts v2.1.2](#)).
- **3-arg vs 4-arg sendServerCommand.** You wrap `sendServerCommand`. Bandits uses the 3-arg broadcast form. Your wrapper chokes on the type signature. Crash on mod interop ([VPS v1.9.0 → Bandits](#)).
- **Unscoped triggerEvent dispatch.** You add a command shim that dispatches `OnServerCommand` for every mod. Spongie's Character Customisation has a guard tuned for one dispatch per cycle. Infinite loop on load ([VPS v1.9.0 → Spongie's](#)).

These don't surface in a single-player test pass. They show up when someone with 20 other mods connects to a Workshop server at 2am and their save corrupts. The post-mortem is a weekend of alt-tabbing between Lua console and `DebugLog-server.txt`.

**PZ Test Kit catches each of these in a one-line counter assertion, run in under a second, offline.**

```lua
-- v2.1.4 double-broadcast regression guard
tests["drop_to_floor_broadcasts_complete_item_exactly_once"] = function()
    local w = PZTestKit.Fixtures.world()
    local cart = makeCart()
    local sq = w:square(10, 10, 0)
    YourMod.dropCartToFloor(cart, sq)
    return Assert.equal(cart:getWorldItem()._private.transmitCompleteCount, 1,
        "transmitCompleteItemToClients fires exactly once")
end
```

That test failed loudly the moment someone would have reintroduced the 4-arg form. Before the kit, we caught that bug in production with dupe items piling up on dedi.

---

## What you get

| Feature | What it buys you |
|---|---|
| **PZ's actual Lua VM** in a 613KB jar | No game install needed. Identical bytecode to in-game. |
| **`vanilla_requires`** | Pull real vanilla PZ Lua (`ISTransferAction`, `ISHandcraftAction`, `ISDropWorldItemAction`) into your test env. Your interceptor tests run against the actual vanilla implementation. When TIS refactors on a patch, you find out on CI, not on the Workshop. |
| **Fixtures library** | Faithful Lua-table stand-ins for `InventoryItem`, `ItemContainer`, `IsoGridSquare`, `IsoWorldInventoryObject`, `IsoPlayer`, `BaseVehicle` pieces. **Every mutating method bumps a counter.** One-liner assertions catch every duplication vector. |
| **Network + event spies** | Patch `sendServerCommand` / `sendAddItemToContainer` / `syncItemModData` / `triggerEvent`. Assert call counts per kind per test. |
| **Dual-VM MP sim** | `PZTestKit.Sim.new({players = 2})` → server + N clients in isolated Kahlua envs with real command bus + ModData sync. Catches 3-arg wrapper bugs and unscoped dispatch before they hit Workshop. |
| **Zero-config discovery** | Drop a `pz-test.lua` at your mod root. Auto-discovers tests in `media/lua/client/<Mod>/Tests/`. |
| **JUnit XML output** | `--junit-xml` for CI. Works with GitHub Actions Test Reporter, VS Code Test Explorer, etc. |
| **Skip support** | `PZTestKit.skip("reason")` + `PZTestKit.skipInGame(...)` for environment-gated tests. Surfaces as `<skipped>` in JUnit, not `<failure>`. |

---

## Quick start

### Prerequisites

- Java 17+ (Java 25 recommended — matches PZ B42's class-file version)
- Your PZ mod with Lua in `media/lua/`
- (Optional) A local PZ install for `vanilla_requires`. Without it, PZ Test Kit falls back to mocks; with it, you exercise real vanilla code paths.

### Install

```bash
git clone https://github.com/4hp-4int/pz-test-kit.git ~/code/pz-test-kit
export PATH="$HOME/code/pz-test-kit:$PATH"
chmod +x ~/code/pz-test-kit/pztest
```

Windows PowerShell:

```powershell
git clone https://github.com/4hp-4int/pz-test-kit.git C:\code\pz-test-kit
$env:Path += ";C:\code\pz-test-kit"
```

### Add `pz-test.lua` to your mod root

```lua
return {
    -- Modules required before each test file runs.
    preload = {
        "YourMod/Core",
        "YourMod/CartData",
    },

    -- SandboxVars defaults. Match your media/sandbox-options.txt.
    sandbox = {
        YourMod = {
            EnableMod = true,
            CapacityMultiplier = 100,
        },
    },

    -- Load real vanilla PZ files. If PZ is installed locally, these are
    -- loaded from the actual game install. On CI without PZ, falls back
    -- to mocks for these modules.
    vanilla_requires = {
        "shared/ISBaseObject",
        "shared/TimedActions/ISBaseTimedAction",
        "shared/TimedActions/ISTransferAction",
    },

    -- (Optional) Cross-mod deps for integration tests.
    -- dependencies = { "../TooltipLib" },

    -- (Optional) Exclude in-game-only test files from offline runs.
    -- test_file_excludes = { "VisualTests.lua" },
}
```

See [`docs/GETTING_STARTED.md`](docs/GETTING_STARTED.md) for the full config reference.

### Run

```bash
cd /path/to/YourMod
pztest                          # auto-discover all test files
pztest --filter durability      # only tests with "durability" in the name
pztest --junit-xml results.xml  # for CI
pztest tests/test_core.lua      # single file
```

---

## The killer feature: counter-based duplication guards

Every mutation-tracking method on a Fixture bumps a counter. Assertions read the counter. When a bug makes something fire N+1 times, the test fails at exactly the right line.

### Vector: `AddWorldInventoryItem` double-broadcast

The 4-arg overload `AddWorldInventoryItem(item, x, y, h)` defaults `transmit=true` and broadcasts `transmitCompleteItemToClients` internally. The 5-arg form `AddWorldInventoryItem(item, x, y, h, false)` doesn't. If your code uses the 4-arg form AND also calls `transmitCompleteItemToClients` manually, every drop produces **two** world items on clients.

```lua
tests["drop_broadcasts_exactly_once"] = function()
    local sq = PZTestKit.Fixtures.square(10, 10, 0)
    local item = PZTestKit.Fixtures.item({ id = 42 })
    YourMod.dropToFloor(item, sq)
    return Assert.equal(item:getWorldItem()._private.transmitCompleteCount, 1,
        "exactly one broadcast")
end
```

### Vector: stale hand ref → forceDropHeavyItems dupe

`ISEnterVehicle:start` fires on both client and server. Both call `forceDropHeavyItems(character)`. If the second call runs with a stale primary hand reference, `AddWorldInventoryItem` fires twice and the dropped item duplicates.

```lua
tests["force_drop_guard_clears_stale_primary_before_second_call"] = function()
    local chr = PZTestKit.Fixtures.player()
    chr:setPrimaryHandItem(cart)
    -- Simulate: cart already dropped by first call, primary ref now stale
    chr._private.primary = cart   -- manually reset to simulate the race
    YourMod.guardedForceDropHeavyItems(chr)  -- second call
    return Assert.equal(sq._private.addWorldInvCalls and #sq._private.addWorldInvCalls or 0, 0,
        "second call with stale ref did not double-drop")
end
```

### Vector: `sendServerCommand` call-count explosion

Every packet sent by your code is captured by `PZTestKit.Fixtures.networkSpy`. Test that a transfer produces exactly one `sendAddItemToContainer` and one `sendRemoveItemFromContainer`, not two of each.

```lua
tests["inventory_to_cart_transfer_produces_one_remove_one_add"] = function()
    local w = PZTestKit.Fixtures.world()
    YourMod.transferToCart(item, playerInv, cartInner)
    if not Assert.equal(w.network:count("sendRemoveItemFromContainer"), 1) then
        w:teardown(); return false
    end
    local ok = Assert.equal(w.network:count("sendAddItemToContainer"), 1)
    w:teardown()
    return ok
end
```

### Vector: cross-mod wrapper bugs (sendServerCommand 3-arg form)

Use the dual-VM sim to prove your wrapper handles both forms.

```lua
tests["wrapper_handles_3arg_broadcast_form"] = function()
    local sim = PZTestKit.Sim.new({ players = 2 })
    sim.server:exec([[
        -- Bandits-style 3-arg call. Vanilla broadcasts to all clients.
        sendServerCommand("Bandits", "SyncHealth", { npcId = 1 })
    ]])
    sim:flush()
    -- Your wrapper must not have crashed trying to `player:getOnlineID()` on
    -- a string that's actually the module name.
    return Assert.isTrue(sim.clients[1]:sawCommand("Bandits", "SyncHealth"))
end
```

Every one of these tests is < 10 lines and runs in milliseconds. Maintaining them costs less than debugging one Workshop report.

---

## Fixtures cheat sheet

Full reference in [`docs/FIXTURES.md`](docs/FIXTURES.md). Inventory:

| Factory | Mirrors | Counters worth asserting on |
|---|---|---|
| `Fixtures.item(opts)` | `InventoryItem` | `setWorldItemCount`, `setJobDeltaCount` |
| `Fixtures.container(opts)` | `ItemContainer` | `drawDirtyCount`, `dirtyCount`, `flagForHotSaveCount` |
| `Fixtures.square(x, y, z)` | `IsoGridSquare` | `transmitRemoveCount`, `addWorldInvCalls[].argCount` |
| `Fixtures.worldItem(item, sq)` | `IsoWorldInventoryObject` | `removeFromWorldCount`, `removeFromSquareCount`, `setSquareNilCount`, `transmitCompleteCount`, `setIgnoreRemoveSandboxCount` |
| `Fixtures.player(opts)` | `IsoPlayer` | `setPrimaryCount`, `setSecondaryCount`, `removeFromHandsCount`, `removeAttachedItemCount` |
| `Fixtures.worldItem`'s lifecycle | `IsoWorldInventoryObject` methods | one counter per vanilla method |
| `Fixtures.weapon / firearm / zombie` | `HandWeapon`, `IsoZombie` | 60+ getters/setters each |
| `Fixtures.networkSpy()` | `sendServerCommand` / `sendAddItemToContainer` / `syncItemModData` / etc. | `.count(kind)`, `.callsFor(kind)` |
| `Fixtures.eventSpy()` | `triggerEvent` / `LuaEventManager:triggerEvent` | `.count(eventName)` |
| `Fixtures.world()` | Top-level: wires `getCell()`, `getWorld()`, network + event spies | auto `teardown()` |
| `Fixtures.withSandbox(ns, overrides, fn)` | Scoped `SandboxVars.X` override | Correct restore on exit |

---

## Vanilla requires — test against real PZ code

`vanilla_requires` in your `pz-test.lua` pulls files from your local PZ install into the test env:

```lua
vanilla_requires = {
    "shared/ISBaseObject",
    "shared/TimedActions/ISBaseTimedAction",
    "shared/TimedActions/ISTransferAction",
},
```

When `ISTransferAction:transferItem` gets called by your interceptor, it's the REAL vanilla implementation — the one with the floor-branch, the clothing-refresh path, the radio/candle swap, etc. If TIS refactors that file in the next patch, your CI tells you before your users do.

**CI without a PZ install:** the kit falls back to mocks and logs a warning. To catch vanilla drift, run CI on a runner with PZ installed (or stash the vanilla files in your repo).

Full details: [`docs/VANILLA_REQUIRES.md`](docs/VANILLA_REQUIRES.md).

---

## Dual-VM MP tests

Real multiplayer testing — server + N clients in fully isolated envs, connected by a command bus.

```lua
tests["observer_client_sees_kill_broadcast"] = function()
    local sim = PZTestKit.Sim.new({ players = 2 })

    for i = 1, 2 do
        sim.clients[i]:exec([[
            _saw = false
            Events.OnServerCommand.Add(function(mod, cmd, args)
                if mod == "YourMod" and cmd == "kill" then _saw = true end
            end)
        ]])
    end

    sim.server:exec([[
        sendServerCommand("YourMod", "kill", { zombieId = 42 })
    ]])
    sim:flush()

    if not Assert.isTrue(sim.clients[1]:sawCommand("YourMod", "kill")) then return false end
    return Assert.isTrue(sim.clients[2]:sawCommand("YourMod", "kill"))
end
```

| Call | What it does |
|------|-------------|
| `PZTestKit.Sim.new({ players = N })` | server + N clients, each in its own Kahlua runtime |
| `sim.server:exec(source)` / `sim.clients[i]:exec(source)` | run Lua source in that endpoint |
| `sim:flush()` | drain sync queue, deliver commands, fire `OnServerCommand` / `OnClientCommand` |
| `endpoint:sent()` | commands this endpoint emitted |
| `endpoint:received()` | commands this endpoint received |
| `endpoint:sawCommand(module, command)` | quick bool check |

### What the sim catches

- `sendServerCommand` 3-arg vs 4-arg wrapper bugs
- Unscoped `triggerEvent` dispatches that break other mods' guards
- Cross-client observer updates
- `OnClientCommand` → server handler chains
- ModData replication via `syncItemModData`

---

## Skip support (for tests that don't apply in this environment)

Offline tests that synthesize fake state can't run in-game. In-game tests that need real world state can't run offline. Mark them skipped rather than faking success:

```lua
tests["synthesized_recipe_test"] = function()
    if _pz_module_sources == nil then
        return PZTestKit.skip("offline-only: synthesizes a fake ISHandcraftAction")
    end
    return realInGameTest()
end
```

Or via the convenience gate when registering:

```lua
PZTestKit.skipInGame(TestRunner, "offline_only_case", function()
    -- runs only under pz-test-kit, skipped when running in real PZ
end)
```

Skipped tests surface as `<skipped>` in JUnit XML — CI shows them as skipped, not failed.

---

## CI integration

### GitHub Actions (composite action, recommended)

```yaml
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
```

### GitHub Actions (manual, pin a version)

```yaml
- uses: actions/setup-java@v4
  with: { distribution: 'temurin', java-version: '25' }
- run: |
    git clone --depth 1 --branch v1.1 \
      https://github.com/4hp-4int/pz-test-kit.git "$RUNNER_TEMP/pz-test-kit"
    cd "$RUNNER_TEMP/pz-test-kit/kahlua"
    javac -cp kahlua-runtime.jar \
      TestPlatform.java KahluaTestRunner.java DualVMSim.java \
      StubbingClassLoader.java PZTestKitLauncher.java
    chmod +x "$RUNNER_TEMP/pz-test-kit/pztest"
    "$RUNNER_TEMP/pz-test-kit/pztest" "$GITHUB_WORKSPACE" --junit-xml test-results.xml
```

`--junit-xml` output pairs with [dorny/test-reporter](https://github.com/dorny/test-reporter) or [EnricoMi/publish-unit-test-result-action](https://github.com/EnricoMi/publish-unit-test-result-action) to surface test results on PRs.

---

## Patterns for advanced mods

Real case studies with test-first framing:

- [Container override + MP capacity sync](docs/PATTERNS.md#container-override)
- [Interceptor pattern (ISInventoryTransferAction hook)](docs/PATTERNS.md#interceptor)
- [Timed action MP-safety (primitives-only constructor)](docs/PATTERNS.md#timed-action-mp-safety)
- [ModData schema migration](docs/PATTERNS.md#moddata-migration)
- [OnBreak hook (weapon destruction with state preservation)](docs/PATTERNS.md#onbreak-hook)

Each shows a bug we shipped to Workshop, the test that would have caught it, and the refactor the test implies.

---

## How it works

### The Kahlua Runtime Jar

PZ ships `projectzomboid.jar` (~40MB) with the entire game. Inside it, `se/krka/kahlua/` is the Kahlua Lua VM — an open-source Lua 5.1 implementation in Java. We extract the VM classes plus 3 stub classes that disable PZ's debug assertions:

```java
// zombie/core/Core.java — disables debug checks in KahluaTableImpl.rawset()
public class Core { public static boolean debug = false; }
```

TIS patched `KahluaTableImpl.rawset()` to check `Core.debug` on every table write. Without the stub, this pulls in PZ's entire debug infrastructure. Setting `debug = false` short-circuits the check.

Result: **613KB jar** running PZ's Lua VM standalone. No rendering, networking, or world simulation. Just the bytecode interpreter — the one your mod actually runs under.

### The Stubbing ClassLoader

The Kahlua jar references hundreds of PZ Java classes (`zombie.characters.IsoPlayer`, etc.) in its constant pool. Most are dead refs guarded by `Core.debug = false`, but the JVM resolves lazily and `NoClassDefFoundError`s on the first call through a missing class.

`StubbingClassLoader` generates minimal empty bytecode for any `zombie.*` class name on demand. For two classes with actual methods called at runtime (`LuaManager.getLuaStackStrace`, `ExceptionLogger.logException`), hand-written stubs live in `kahlua/stubs/`.

### The Require Resolver

`require "YourMod/Core"` resolves against a pre-scanned index of `media/lua/{shared,client,server}/**/*.lua`. Shared beats client beats server on conflicts (matches real PZ). Core PZ modules the kit can't provide (`ISUI/*`, `luautils`, `ISBaseTimedAction` if vanilla_requires isn't configured) are stubbed to nil.

### The Mock Layer

Mocks replace the **data source**, not the **runtime**. Instead of spawning a real `HandWeapon` Java object, we create a Lua table with the same getter/setter interface. Private state lives in closures, so `weapon._someField = value` writes don't silently corrupt mock behavior — matching real PZ's Java-object restrictions. If your tests rely on direct field writes to control state, they'll fail offline in exactly the same way they'd fail in-game.

---

## Troubleshooting

**`pztest: cannot find kahlua-runtime.jar`** — The jar is in `pz-test-kit/kahlua/`. If you downloaded the release zip, extract preserving the directory structure.

**`Cannot find mock_environment.lua`** — The wrapper scripts `cd` into `pz-test-kit/kahlua/` before invoking Java. If you're invoking `java` directly, do the same.

**`require 'X/Y' failed`** — The resolver only indexes `media/lua/{shared,client,server}/`. Custom Lua roots: open an issue.

**`PZ install not found — falling back to mocks for 3 entries`** — `vanilla_requires` wants a local PZ install. Set `PZ_INSTALL_DIR` env var, or install PZ via Steam in a default path, or accept the fallback (mocks satisfy the surface, but you lose vanilla-drift detection on CI).

**Tests pass offline but fail in-game** — Your test may rely on mock-only behavior (writing to `weapon._privateField`, overriding `weapon.getX` methods). Real PZ's HandWeapon Java proxy rejects both. Use `PZTestKit.Fixtures.weapon({...})` for state you need to control — it's a Lua table in both environments.

**Tests pass locally but fail on CI** — Check `vanilla_requires`. Your local env probably loads real vanilla ISBaseTimedAction (which sets `o.character`); CI falls back to the kit's mock. Either (a) pre-stage vanilla files in CI, or (b) make sure the kit's mock satisfies your test's minimum expectations.

---

## Files

```
pz-test-kit/
├── pztest                   # bash wrapper
├── pztest.ps1               # PowerShell wrapper
├── pztest.bat               # cmd wrapper
├── action.yml               # GitHub Actions composite action
├── README.md                # this file
├── docs/
│   ├── GETTING_STARTED.md   # step-by-step for first-time users
│   ├── FIXTURES.md          # full API reference with counter/vector docs
│   ├── VANILLA_REQUIRES.md  # when/how to load real vanilla PZ files
│   └── PATTERNS.md          # case studies — container overrides, interceptors, etc.
├── examples/MyMod/          # runnable example mod
├── kahlua/
│   ├── kahlua-runtime.jar   # 613KB self-contained Kahlua VM
│   ├── KahluaTestRunner.java
│   ├── PZTestKitLauncher.java
│   ├── StubbingClassLoader.java
│   ├── DualVMSim.java
│   ├── TestPlatform.java
│   ├── mock_environment.lua
│   ├── require_resolver.lua
│   ├── config_loader.lua
│   ├── post_scripts.lua
│   ├── test_executor.lua
│   ├── Assert.lua
│   ├── Fixtures.lua
│   ├── context/server.lua
│   └── stubs/zombie/{core,Lua,debug}/
└── tools/
    └── pz_script_parser.py
```

## License

Apache 2.0 (same as Kahlua itself).
