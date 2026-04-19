# PZ Test Kit

Offline test framework for Project Zomboid Build 42 mods. Runs your mod's Lua tests in seconds without launching the game — **on PZ's actual Kahlua Lua VM**.

Not a simulation. Not a different Lua implementation. The same `se.krka.kahlua` bytecode interpreter that runs inside the game, extracted into a 613KB self-contained jar.

Also runs **MP sync tests** on a simulated server + N-client topology via a dedicated dual-VM harness — catches `sendServerCommand` bugs, cross-client state divergence, and event-dispatch regressions offline.

## Why This Exists

PZ doesn't use standard Lua or LuaJIT. It uses **Kahlua** — a custom Lua 5.1 interpreter written in Java, patched by The Indie Stone. String patterns, number coercion, metatable behavior, `pcall` semantics — all of these can differ between Kahlua and any standard Lua you test against. If you're testing your mod against LuaJIT or standard Lua 5.1, you're testing against *a different language runtime* than the game uses.

PZ Test Kit gives you:

- **PZ's actual Lua VM** in a 613KB jar — no game install needed
- **Zero-config discovery** — drop a `pz-test.lua` at your mod root, run `pztest`, done
- **Full PZ-style `require`** — resolves paths against `media/lua/{shared,client,server}/**/*.lua` automatically, no hand-listed module order
- **Dual-VM MP harness** — `PZTestKit.Sim.new({players = N})` spins up server + N clients in fully isolated Kahlua envs with a command bus and ModData sync
- **Mock PZ API** — player, weapons (60+ getters/setters), items, inventory, events, sandbox vars, GameTime, IsoZombie, climate
- **Closure-based weapon mocks** — write operations behave like real PZ's Java-object restrictions, catching tests that rely on mock-only side effects
- **Assert library** — `equal`, `nearEqual`, `greater`, `notNil`, `isTrue`, etc. with auto-generated failure messages

## Quick Start

### Prerequisites

- Java 17+ (`java -version` to check — Java 25 recommended to match PZ B42)
- Your PZ mod with Lua code in `media/lua/`

### 1. Install the kit

Clone the repo and put `pztest` on your PATH (or invoke it with a full path):

```bash
git clone https://github.com/4hp-4int/pz-test-kit.git ~/code/pz-test-kit

# Linux/macOS/git-bash:
export PATH="$HOME/code/pz-test-kit:$PATH"
chmod +x ~/code/pz-test-kit/pztest

# Windows PowerShell: add to $profile
$env:Path += ";C:\code\pz-test-kit"
```

### 2. Add a `pz-test.lua` to your mod root

This is the only config file. Optional — but needed if your tests assume certain modules are loaded or SandboxVars have defaults.

```lua
-- YourMod/pz-test.lua
return {
    -- Modules to require() before each test file runs.
    preload = {
        "YourMod/Core",
        "YourMod/WeaponData",
    },

    -- SandboxVars defaults. If your mod reads SandboxVars.YourMod.X without
    -- a nil check, set the expected value here.
    sandbox = {
        YourMod = {
            EnableX = true,
            BuffMultiplier = 1.0,
        },
    },

    -- (optional) extra script files providing weapon/item definitions.
    -- Default is `<modRoot>/weapon_scripts.lua` if present.
    -- extra_scripts = { "tools/test/items.lua" },

    -- (optional) exclude legacy/hub test files from auto-discovery.
    -- test_file_excludes = { "LegacyHub.lua" },

    -- (optional) enable strict mock mode — rejects writes to unknown fields
    -- on mock weapons, matching real PZ's Java-object behavior. Opt-in.
    -- strict_mocks = true,

    -- (optional) cross-mod dependencies. Path is relative to this mod's root.
    -- Every dependency's media/lua/ tree is indexed into the require resolver,
    -- so `require "OtherMod/Core"` works from your test code.
    -- dependencies = {
    --     "../TooltipLib",
    --     { path = "../SharedLib" },
    -- },
}
```

### 3. Write a test

```lua
-- YourMod/media/lua/client/YourMod/Tests/test_core.lua
require "YourMod/Core"

local Assert = PZTestKit.Assert
local tests = {}

tests["buff_at_100_kills"] = function()
    return Assert.nearEqual(YourMod.getBuff(100), 0.5, 0.001, "100 kills = 0.5 buff")
end

tests["validates_melee"] = function()
    local weapon = instanceItem("Base.Axe")
    return Assert.isTrue(YourMod.isValidWeapon(weapon), "Axe is valid")
end

return tests
```

### 4. Run tests

From your mod's root directory:

```bash
pztest
```

Or pass a mod root explicitly:

```bash
pztest /path/to/YourMod
```

Output:

```
====================================================
PZ Test Kit — Kahlua Runner (PZ's actual Lua VM)
====================================================
Mod root:         /path/to/YourMod
Indexed modules:  12
Test files:       3

--- media/lua/client/YourMod/Tests/test_core.lua (10 tests) ---

====================================================
KAHLUA TOTAL: 10 tests, 10 passed, 0 failed, 0 errors
====================================================
```

Tests are auto-discovered from:
- `tests/test_*.lua`
- `media/lua/client/<ModName>/Tests/test_*.lua`
- `media/lua/client/<ModName>/Tests/*Tests.lua` (VPS convention)

## Dual-VM MP Tests

Real multiplayer testing — server + N clients in fully isolated envs, connected by a command bus.

```lua
require "YourMod/Core"
local Assert = PZTestKit.Assert
local tests = {}

tests["kill_broadcast_reaches_all_clients"] = function()
    local sim = PZTestKit.Sim.new({ players = 2 })

    -- Each client registers a listener
    for i = 1, 2 do
        sim.clients[i]:exec([[
            _saw = false
            Events.OnServerCommand.Add(function(mod, cmd, args)
                if mod == "YourMod" and cmd == "kill" then _saw = true end
            end)
        ]])
    end

    -- Server broadcasts
    sim.server:exec([[
        sendServerCommand("YourMod", "kill", { zombieId = 42 })
    ]])
    sim:flush()  -- routes queued messages, fires OnServerCommand listeners

    if not Assert.isTrue(sim.clients[1]:sawCommand("YourMod", "kill")) then return false end
    return Assert.isTrue(sim.clients[2]:sawCommand("YourMod", "kill"))
end

tests["moddata_replicates_via_syncItemModData"] = function()
    local sim = PZTestKit.Sim.new({ players = 1 })

    -- Both sides spawn a weapon with the same ID
    local setup = [[
        _wpn = instanceItem("Base.Axe")
        _wpn._id = 42
        _wpn.getID = function() return 42 end
        getPlayer():getInventory():AddItem(_wpn)
    ]]
    sim.server:exec(setup)
    sim.clients[1]:exec(setup)

    -- Server mutates + syncs
    sim.server:exec([[
        _wpn:getModData().YourMod = { kills = 50 }
        syncItemModData(getPlayer(), _wpn)
    ]])
    sim:flush()

    -- Client sees replicated ModData
    sim.clients[1]:exec([[
        sendServerCommand("Probe", "report", { kills = _wpn:getModData().YourMod.kills })
    ]])
    return Assert.equal(sim.clients[1]:sent()[1].args.kills, 50)
end

return tests
```

### Sim API

| Call | Description |
|------|-------------|
| `PZTestKit.Sim.new({ players = N })` | Create sim with 1 server + N clients |
| `sim.server:exec(source)` / `sim.clients[i]:exec(source)` | Run Lua source in the endpoint's env |
| `sim:flush()` | Drain sync queue, deliver commands, fire `OnServerCommand` / `OnClientCommand` |
| `endpoint:sent()` | List of commands this endpoint emitted |
| `endpoint:received()` | List of commands this endpoint received |
| `endpoint:sawCommand(module, command)` | Quick bool check |

### What the sim catches

- `sendServerCommand` 3-arg vs 4-arg wrapper bugs (Bandits-class crashes)
- Unscoped `triggerEvent` dispatches that break other mods' guards (Spongie-class freezes)
- Cross-client observer updates ("client B sees A's kill")
- `OnClientCommand` → server handler chains
- ModData replication via `syncItemModData`

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

### The Stubbing ClassLoader

The Kahlua jar references hundreds of PZ Java classes (`zombie.characters.IsoPlayer`, `zombie.Lua.LuaManager`, etc.) in its constant pool. Most are dead references (guarded by `Core.debug = false`), but the JVM still resolves class references lazily and throws `NoClassDefFoundError` if the class is missing.

`StubbingClassLoader` generates minimal empty bytecode for any `zombie.*` class name on demand. For the two classes with actual methods called at runtime (`LuaManager.getLuaStackStrace`, `ExceptionLogger.logException`), hand-written stubs live in `kahlua/stubs/`.

### The Require Resolver

`require "YourMod/Core"` looks up modules from a pre-scanned index of `media/lua/{shared,client,server}/**/*.lua`. Shared beats client beats server on conflicts. Core-PZ modules that the kit can't provide (`ISUI/*`, `luautils`, `ISBaseTimedAction`) are stubbed to nil.

### The Mock Layer

Mocks replace the **data source**, not the **runtime**. Instead of spawning a real `HandWeapon` Java object, we create a Lua table with the same getter/setter interface. Private state lives in closures, so `weapon._someField = value` writes don't corrupt mock behavior — matching real PZ's Java-object restrictions.

```lua
local weapon = instanceItem("Base.Axe")
weapon:setMaxDamage(2.5)
weapon:getMaxDamage()       -- 2.5
weapon:getModData().foo = "bar"
instanceof(weapon, "HandWeapon")  -- true
```

Sharpness, condition, damage scaling, etc. match real PZ's Java implementation.

## Advanced

### Adding mocks your mod needs

If your mod calls a PZ API we don't mock, add it yourself:

```lua
-- In a setup file loaded before your tests (or in pz-test.lua's preload):
function _pz_create_mock_zombie(opts)
    opts = opts or {}
    local z = {
        _type = "IsoZombie",
        _health = opts.health or 1.8,
    }
    z.getHealth = function(self) return self._health end
    z.setStaggerBack = function(self, v) self._staggerBack = v end
    z.isAlive = function(self) return self._health > 0 end
    return z
end
```

### Parsing vanilla weapon data

`tools/pz_script_parser.py` reads PZ's actual `weapon.txt` and generates a Lua table:

```bash
python tools/pz_script_parser.py --lua --filter "Base.Axe,Base.Pistol" > weapon_scripts.lua
```

### Offline-only tests

Some tests only make sense offline (e.g., they synthesize a fake
`ISHandcraftAction`). Gate them with `_pz_module_sources`, which is set by
pz-test-kit's require resolver and nil in real PZ:

```lua
local IS_OFFLINE = _pz_module_sources ~= nil
if IS_OFFLINE then
    TestRunner.registerSync("my_offline_only", function() ... end)
end
```

## Troubleshooting

**`pztest: cannot find kahlua-runtime.jar`** — The jar is in `pz-test-kit/kahlua/`. If you cloned from git, make sure LFS is configured. If you downloaded the release zip, extract it preserving the directory structure.

**`Cannot find mock_environment.lua`** — The wrapper scripts `cd` into `pz-test-kit/kahlua/` before invoking Java, which is how the runner finds its helpers. If you're invoking `java` directly, do the same.

**`require 'X/Y' failed`** — The resolver only indexes `media/lua/{shared,client,server}/`. If your mod uses a custom lua root, let us know — we can add config support.

**Tests pass offline but fail in-game** — Your test may rely on mock-only behavior (common cases: writing to `weapon._privateField`, overriding `weapon.getX` methods). Real PZ's HandWeapon Java proxy rejects both. Use `TestHelpers.createMockWeapon({...})` for state you need to control — it's a Lua table in both environments.

## Files

```
pz-test-kit/
├── pztest                  # bash wrapper (Linux/macOS/git-bash)
├── pztest.ps1              # PowerShell wrapper
├── pztest.bat              # Windows cmd wrapper
├── README.md               # this file
├── docs/GETTING_STARTED.md
├── examples/MyMod/         # 38 example tests
├── kahlua/
│   ├── kahlua-runtime.jar  # 613KB self-contained Kahlua VM
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
│   └── stubs/zombie/{core,Lua,debug}/
└── tools/
    └── pz_script_parser.py
```

## License

Apache 2.0 (same as Kahlua itself).
