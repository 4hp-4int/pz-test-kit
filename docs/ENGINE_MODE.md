# Engine mode — real PZ classes in offline tests

Opt-in per mod via `engine = true` in `pz-test.lua` (or `--engine` /
`--no-engine` on the CLI). With it, the kit loads `projectzomboid.jar` into
its classloader, parses the **vanilla + mod scripts with PZ's own
ScriptManager**, and gives tests:

```lua
PZEngine.available()               -- false on a machine with no PZ install
local bulb  = instanceItem("Base.LightBulb")     -- real zombie.inventory item
local sm    = getScriptManager()                 -- real, fully parsed
local axe   = instanceItem("Base.Axe")           -- real HandWeapon
instanceof(axe, "HandWeapon")                    -- true (real class walk)
```

Engine test files guard themselves:

```lua
if not (PZEngine and PZEngine.available()) then return {} end
```

so CI without a game install runs zero engine tests instead of failing.

## Why this works headless

The dedicated server runs the whole script/item layer with no OpenGL and no
FMOD — headless is a supported mode of these classes. `EngineBridge` reaches
the same state without the server's world boot:

1. `StubbingClassLoader.addJar(projectzomboid.jar)` at runtime. Precedence:
   **stubs/ dir → kahlua-runtime.jar → real PZ classes → synthesized
   empties.** The stubs keep absorbing the GL/FMOD-adjacent edges (Core,
   LuaManager, DebugOptions); everything else resolves real.
2. Our own walk of `media/scripts` (PZ's `Load()` is welded to
   ZomboidFileSystem's full game-home boot; `ParseScript(mode, text)` is
   public), with the same per-file bookkeeping `Load()` maintains
   (`currentLoadFileMod` etc.) and the same `ScriptParser.stripComments`
   preprocessing.
3. The same post-parse passes `Load()` runs — `loadScripts(Init, types)` and
   `resolveItemTypes()` — over an **allowlist** of script types (items,
   recipes, entities, fluids…). Vehicles (Lua-table storage),
   ragdoll/physics (Bullet natives), Xui (UI) and asset types are skipped,
   not stubbed.
4. Lua exposure mirrors `LuaManager` exactly: `KahluaConverterManager` +
   number/array converters + `LuaJavaClassExposer.exposeLikeJavaRecursively`
   over a curated class list — the same machinery that builds
   `__classmetatables` in game. Extend the list per mod with
   `engine_expose = { "zombie.Foo" }` in `pz-test.lua`.

Boot is once per JVM (~2s), envs are per test file as always.

## What it buys over mocks

- **Real units.** The engine stores `HungerChange = -10` as `-0.1`, colors
  as Java floats (`setColorRed(0.9)` reads back `0.89999997…`). A mock can
  encode your wrong assumption; a real `Food` can't.
- **Real script parsing.** Your `media/scripts/*.txt` goes through the real
  parser — a recipe that silently stopped registering shows up offline.
- **Real modData / real method dispatch** on real classes.

## What it does not cover

Characters, world, network. `IsoPlayer`, squares, events, sync — still
mocks. The engine's scope is the script/item layer; probes on a live server
(pz-shell) remain the oracle for everything stateful.

## Maintenance notes

- **Stubs dir now precedes the runtime jar on the classpath** (both
  wrappers). The jar bakes stub copies at build time; jar-first meant an
  edited stub silently lost to its stale baked copy until a jar rebuild.
- When a real class trips over a missing stub member, the error names it
  (`NoSuchMethodError: Core.getOptionLanguageName`). Add the member to the
  stub, `javac -cp kahlua-runtime.jar -d stubs stubs/zombie/...java`, rerun.
- Engine assertions on floats need tolerance, not equality (see
  SauceTweaks `EnginePackingTests.lua` `near()`).
- Standalone smoke: `java -cp stubs;kahlua-runtime.jar;. EngineBridge`
  from `kahlua/` — boots, mints a bulb, prints PASS/FAIL.
