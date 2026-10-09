# SousVide population: the game's own zombie population, headless

Status 2026-10-08: spawning, leaving and returning, sounds and density WORK;
long-run dynamics (respawn, redistribution, cell unloading over days) do NOT
advance yet. `kahlua/PopSim.java`, `kahlua/native/PopClock.java`.

## What it is

B42's zombie population is native code (`PZPopMan64.dll`) behind thin Java
wrappers (`zombie.popman.ZombiePopulationManager`, `zombie.MapCollisionData`).
PopSim loads that library into an engine VM and drives its natives the way a
dedicated server does, over the real metagrid and the map's real zombie
intensity. Nothing is ever written to a real save: the library gets a temp
save directory and `Core.noSave`.

## Lua API (`PZEngine.*`, after `PZEngine.loadWorld()`)

| Call | Does |
|---|---|
| `popInit()` | boots the population (true, or nil + error) |
| `popArea(x, y, w, h)` | the player's loaded area, in squares (chunks load; zombies left outside go back to the library as virtual) |
| `popStep(minutes [, wallMs [, subSteps]])` | advances game time; returns how many zombies were made real |
| `popTake([x, y])` | the zombies made real since the last take (nearest first): `x, y, z, dir, standing, tx, ty, id, state, descriptor` |
| `popKill(id)` / `popVirtualize(id)` / `popMove(id, x, y)` | a real zombie died / left the loaded world / moved |
| `popSound(x, y, radius, volume)` | a world sound, radius already multiplied by hearing |
| `popCells()` | the library's loaded cells (256-square map cells): `cx, cy, current, desired, lastRepop` |
| `popDensity(x0, y0, x1, y1)` | the map's zombie intensity per chunk (no library needed) |
| `popStatus()` | ready, clock, hour, real, made, killed, area... |
| `popRooms(name, cx0, cy0, cx1, cy1 [, max])` | rooms of the loaded map by name (`gasstore`...) over map cells: `name, x, y, w, h` |
| `popRadar()` | the library's radar; answers but reports 0 (open) |

## Things learned (each cost a debugging session)

- **SousVide had zombie density 0 everywhere.** `IsoWorld.zombieVoronois` was
  null headless, so every metagrid loader thread NPE'd at the intensity step,
  after rooms and buildings had loaded (`IsoMetaGrid.java:2324`). `loadWorld`
  now sets them (`installZombieVoronois`; vanilla's
  `media/lua/server/Zombies/VoronoiNoise.lua` values when the Lua table is
  absent). B42 intensity is small: Muldraugh max ~10 per chunk, ~1 average.
- **`n_hasDataForThread()` must be called after each update.** The ask itself
  hands the main side's queued work (chunk loads, areas, sounds) to the worker
  (`ZombiePopulationManager.updateMain :629-633`). Without it nothing spawns.
- **The worker runs until both libraries are idle**
  (`MapCollisionData.MCDThread.shouldWait :500`), not one pass per update.
- **The library reads the wall clock** (`QueryPerformanceCounter`,
  `GetTickCount64`, `GetSystemTimeAsFileTime`, its only time imports).
  `PopClock` patches those three entries of ITS import table to JNA callbacks
  answering virtual time (compiled at run time against projectzomboid.jar,
  which ships JNA). `popStep` advances it 2.5 s per game minute (the default
  one-hour day). `-Dpopsim.realclock` turns it off.
- **Its randomness is not clock-seeded**: a fixed clock epoch does not make
  runs repeatable. Sample several runs.

## Measured (Muldraugh, 10600,9800, a 17x17-chunk loaded area)

- First sight: 10-16 zombies made real, in groups of 1-3, 18-94 tiles out.
  The two map cells hold ~110-130 (Muldraugh) and ~230-260 (east) zombies
  in all; the rest stay virtual.
- Walk 120 tiles east and back: Muldraugh's zombies are virtualized and come
  back (8-15).
- An alarm (radius 200, ten minutes) draws 34-41 moving zombies in most
  runs; in some runs (1 in 4 to 2 in 4) the library loads no neighbour cells
  and none come. Not a per-sound roll: ten repeats change nothing. Open.

## The Arena at real places

`Arena:clearAt{ x, y, radius = 40, link = 6, walkSpeed = 2.0, toughness }`
asks the population who stands within `radius` of the spot, groups them
(`link` tiles), walks a greedy nearest-first route between groups on the arena
clock and fights each (`Arena:fightGroup`: four in reach at a time, no backing
off), reporting deaths back (`popKill`). `zeds = {...}` fights a given draw
instead (the same draw for several weapons: a cleared place stays cleared).

All 26 gas stations of the map (VorpallySauced
`tools/analysis/arena_clear_place_tests.lua`, Normal zombies, Strength and
Fitness 5): 0-69 zombies within 40 tiles (median 20); a level-0 baseball bat
clears 19 of the 25 occupied ones and fails at every one over 25 zombies; a
level-0 golf club clears 6; a level-5 axe 24 (after the swing-arc fix,
2026-10-09).

**The world seed shapes towns.** The zombie voronoi (seeded from the world
seed) blanks whole patches: with SousVide's seed 0, Muldraugh's density is a
strip along the main road south of y 9800 and its gas station has nobody near.
Another save's Muldraugh differs. Seed control is open.

## Open

- Respawn, redistribution and cell unloading do not move over three stepped
  days (cell numbers identical day to day); likely something else the library
  waits on.
- The radar reports 0.
- World seed control (the voronoi seed), the metagrid visualiser.
