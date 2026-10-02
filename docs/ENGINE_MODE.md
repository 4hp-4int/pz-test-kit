# Engine mode — real PZ classes in offline tests

Opt-in per mod via `engine = true` in `pz-test.lua` (or `--engine` /
`--no-engine` on the CLI). With it, the kit loads `projectzomboid.jar` into
its classloader, parses the **vanilla + mod scripts with PZ's own
ScriptManager**, and gives tests:

```lua
PZEngine.available()               -- false on a machine with no PZ install
local bulb = PZEngine.instanceItem("Base.LightBulb")  -- real zombie.inventory item
local sm   = getScriptManager()                       -- real, fully parsed
local axe  = PZEngine.instanceItem("Base.Axe")        -- real HandWeapon
instanceof(axe, "HandWeapon")                         -- true (real class walk)
```

## The global `instanceItem` is a separate, opt-in decision

`PZEngine.instanceItem` is always real. The **global** `instanceItem` — what
legacy suites and mod harness factories call — is only upgraded when the mod
sets `engine_items = true`, and even then it *chains*: real item when the
parsed registry knows the type, delegate to the previous factory for
contrived test-only types.

Why not always: flipping VPS's 1000-test legacy suite to real items surfaced
~25 tests that legitimately depend on mock affordances — direct `_stats`
writes, spy-wrapped methods, dual-VM sim items — none of which a real Java
object can offer. Migrating a legacy suite to `engine_items = true` is
per-test work, not a switch. New engine tests should use
`PZEngine.instanceItem` explicitly and skip the question.

Engine test files guard themselves:

```lua
if not (PZEngine and PZEngine.available()) then return {} end
```

so CI without a game install runs zero engine tests instead of failing.

## The real wire (`engine_wire`)

`PZEngine.wireRoundTrip(tbl)` returns `(received, drops)`: the payload as
the other side of a `sendClientCommand` / `sendServerCommand` would see
it, serialized through the real `zombie.network.TableNetworkUtils` — the
exact save/load pair GameClient (:1858) and GameServer (:3487) run on
every command — plus a 1..N array describing the top-level entries the
wire dropped. Use it in any engine test to pin a command payload as
wire-safe without spinning up a sim.

With `engine_wire = true` in `pz-test.lua`, DualVMSim command payloads
ride this serialization automatically: serialized once at send (vanilla's
ERROR line per dropped entry, `[Sim]`-prefixed), deserialized fresh per
delivery so each broadcast target gets its own copy. Consequences tests
can rely on:

- functions and non-string/number keys in a payload **vanish**, exactly
  as on a live server
- a handler mutating its received args **cannot** reach the sender's
  table (the legacy pass-by-reference transport allowed it)
- the endpoint's `sent()`/`received` records keep the *sender's* original
  table — introspection, not transport

Opt-in like `engine_items`, and for the same reason: a sim suite may
legitimately send mock structures the real wire refuses.

**Known boundary:** the wire's InventoryItem tag resolves items via
WorldDictionary registry IDs, which only a loaded world populates. A real
item inside a payload arrives `nil` in the harness but whole on a live
server — world-save layer, outside engine scope. Pin item-in-payload
behavior on the dedi (pz-shell).

## Other mods' items (`engine_mods`, run with `--engine-mods`)

Interop tests want the REAL items of mods you don't own — a gun pack's
magazines, a framework's ammo. List them in `pz-test.lua`:

```lua
engine_mods = {
    "workshop:3722134990/GunsOfMarz",   -- <workshop item id>/<mods folder>
    "../SomeSiblingMod",                -- or a path, relative to the mod root
},
```

and run the files that want them with `pztest --engine-mods <files>`. Each
entry's scripts are parsed after vanilla and before the mod under test.

- **Opt-in per run, never by config alone.** Packs commonly declare
  `module Base` and *redefine vanilla items* — loading eight gun packs swapped
  `Base.Shotgun` out from under an unrelated VPS test. A plain `pztest` stays
  vanilla-faithful.
- **B42 layout:** `common/` + the newest `42*/` folder win over a root
  `media/` (dual-build mods ship B41 content at the root).
- **Same-path script files REPLACE, like the game.** PZ resolves mod files
  by relative path: two sources shipping `media/scripts/ammo/9mm.txt` means
  the later one's file wins wholesale (case-insensitive). The engine collects
  by path before parsing and logs every `[engine] override:` — which matched a
  live dedi's own `overrides media/scripts/...` lines one for one, including
  the GaelGunStore -> Modern Firearms collision that deleted Base.9mmDrum_cat
  and stopped that server loading its world.
- **Missing entries are skipped, not fatal.** Guard suites on
  `PZEngine.modLoaded("<mod.info id>")`.
- **Scripts only.** The mod's Lua never runs; framework behaviour is a job for
  a live server (pz-shell).
- **Gotcha that shaped the implementation:** the list is regex-sniffed from
  `pz-test.lua`, not loaded through a Kahlua env. Building ANY env before boot
  touches `zombie.*` classes while `projectzomboid.jar` is not yet on the
  loader, so `StubbingClassLoader` synthesizes EMPTY ones and caches them —
  every real caller then dies with `NoSuchMethodError`
  (`PZMath.nextPowerOfTwo` in `ObjectSet.tableSize`).

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
