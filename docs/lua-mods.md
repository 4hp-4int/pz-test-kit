# Other mods' Lua in SousVide (`lua_mods`)

`engine_mods` loads other mods' **scripts** (items, recipes) and nothing else.
`lua_mods` runs their **Lua** too, next to the mod under test, the way the
game loads it. It is the interop smoke test: does our mod boot, and keep
working, with Bandits, Rain's Firearms or TooltipLib's other users loaded
beside it?

## Use

MCP:

```
mp_start  mod="VorpallySauced"  lua_mods=["workshop:<id>/<folder>", "../SauceTooltips"]
```

HTTP: `POST /api/mp/<mod>/start {"clients":1, "luaMods":[...]}`.
Runner: `pztest --bridge --lua-mod <spec> --lua-mod <spec>` (one spec per
flag; a `;`-joined list is a POSIX path list to Git Bash, which rewrites it
before Java sees it).

A spec is what `engine_mods` takes: `workshop:<id>/<folder>` (the Steam
Workshop copy; `PZ_WORKSHOP_DIR` overrides where that is) or a path, absolute
or relative to the mod under test. B42 layout resolves to `common/` plus the
newest `42*` folder.

Every side of the MP session loads them (the server side: shared + server, as
a dedi; a client: shared + client + server). They imply **full mode** (every
vanilla file of the side's folders runs first, as in game): third-party code
assumes all of vanilla exists. Pass `full: false` to override.

## Load order (what the game does)

`LuaManager.LoadDirBase(folder)`, per folder (shared, then client, then
server): vanilla's files sorted case-insensitively, then **one mod at a time**
in mod order, each mod's `common/` and version files together, sorted
case-insensitively. A path already run is not run again; a mod file at a
vanilla path runs at vanilla's place, instead of it.

Mod order here: the listed mods, then the mod's `dependencies` (pz-test.lua),
then the mod itself; then each mod moves after the mods its `mod.info`
`require=` names (SauceTooltips after TooltipLib). The runner publishes the
result as `_pz_mod_load` (`{mod, folder, name, path}` per file) and the MP boot
runs it. This also fixed an old inaccuracy: the bench used to interleave the
mod and its dependencies by path.

`require` still resolves by name with the mod under test first, then its
dependencies, then the listed mods. A file whose name another mod's file holds
is run by path, so both run, as in game.

`getActivatedMods()` lists the loaded mods (ids from `mod.info`) under
`lua_mods` only; ordinary suites keep the empty list they always had.
Translations of listed mods are merged too.

## Reading the boot report

Each side's report (`mp_start`'s `boot.<side>`):

| field | what |
|---|---|
| `mods` | per mod id: files `loaded`, `failed` |
| `modErrors` | **read first.** A mod file that failed to load (`at = "load <name>"`), or a mod's listener that threw at OnGameBoot / OnServerStarted / OnGameStart / OnCreatePlayer (`at = "<event> <file>:<line>"`). Vanilla's listeners are left out: full mode always has headless noise there |
| `activeMods` | what `getActivatedMods()` returns, in load order |
| `failed`, `events`, `full` | the raw lists (vanilla included) |

For a mod's MP checks with other mods beside it: `node mp-check.mjs
--lua-mods <file.json> <scenarios>` (`--full` for full mode alone, `--keep`
to inspect the last session afterwards).

Then drive the session with `mp_eval` as usual: equip, hit, kill, open a
tooltip; any later error is in that call's result.

## What the game provides that the kit had to learn (2026-10-06)

The first smoke run (nine popular mods beside VorpallySauced) failed ~20 files
per side on kit gaps, not on the mods. Closed, so they no longer hide real
interop results:

- **The game's exposer.** Under `lua_mods`, the kit runs the game's own
  `LuaManager.Exposer.exposeAll` into a scratch table and adds every global
  and class metatable the env still lacks (616 globals, 648 metatables):
  `BloodBodyPartType`, `BodyLocations`, `HaloTextHelper` and the rest. The
  kit's stand-ins win. The GlobalObject functions themselves cannot come
  this way: the real nested class cannot load beside the kit's stub
  `LuaManager` (see the stub's comment), so `exposeAll` stops there.
- **`newrandom()` / `newarray()`** (Kahlua's RandomLib and UserdataArray):
  the game's platform registers them for every env; the kit's did not. Now
  in `TestPlatform`, for every suite.
- **`media/registries.lua`**: run per mod before any Lua, as
  `ModRegistries.init` does (RAF's `RAFTags` live there).
- **Case-insensitive `require`**: the game finds files case-insensitively
  (`require("WeaponSystems/utils/RateOfFire")` loads `Utils/`). Every suite.
- **Other mods' sandbox options** are registered too.
- **`getFileSeparator()`** stand-in.
- **`HaloTextHelper` on MP clients** (`PZEngine.expose`), every MP session:
  without it VPS's upgrade listener threw before recording discoveries, so
  the genesis wire budget had been measured on a broken path (387 bytes in 4
  packets; the real cost is 477 in 6).

Still not handled: `mod.info` `loadModAfter=` / `loadModBefore=` (the game
reads them, `ChooseGameInfo.java:228`); mods reading their own files from
disk (Bandits' `loadFile`).

## Limits

- Headless: no rendering, no sound, the UI is uiview's UIMock. A mod that
  needs Java (a ZombieBuddy agent, its own classes) or real UI fails where the
  game would not; read `modErrors` with that in mind.
- A mod with UI-heavy client code may throw at OnGameStart for the same
  reason. A throw from code that only builds UI is not an interop bug.
- Vanilla's `require` misses are reported (`requireMisses`), not fatal.
- Per session: a running session is never replaced under its user; stop it
  first (`mp_status stop`).

## Teardown

`pztest down` stops every dashboard and SousVide VM on the machine
(`--list` shows them first). The dashboard now stops MP sessions too: on exit,
and after 30 minutes with no call to any side. A VM exits on its own when its
stdin closes, so a dashboard that is killed outright no longer leaves its VMs
running.
