# SousVide performance testing

SousVide runs PZ's own Kahlua interpreter and the real game classes, so a
mod's Lua costs here what it costs there: per call, per kill, per tick, per
minute, per player. It cannot tell you frame time, render cost, the game's
GC pauses or network latency. Use it for **comparisons and budgets**: A
against B in the same process, and regression limits with headroom.

## Lua cost: `PZTestKit.Perf` (`kahlua/perf.lua`)

```lua
local Perf = PZTestKit.Perf
local r = Perf.measure("recordKill", function(w, p, z) Life.recordKill(w, p, z, d) end,
    { runs = 2000, warmup = 300, setup = function(i) return w, p, freshZombie() end })
Perf.print(r)                              -- median, p95, mean, min, max (us)
local ok, msg = Perf.budgetUnits(r, "median_us", 1.5)
Perf.print(Perf.compare("genome on the kill path", off, on))
Perf.print(Perf.memory("pack", fn, { runs = 3000 }))   -- bytes per call, coarse
```

What the harness does, and why (each was measured, 2026-10-06):

- **Warms the whole VM first** (`Perf.warmVM`). The JVM compiles Kahlua's
  interpreter loop in tiers: a 100-iteration Lua loop ran at ~44 us for the
  first windows and ~2.7 us once fully compiled. The compiled code is the
  interpreter, shared by all Lua, so one warm-up per process serves every
  measurement. The game runs for hours; the warm interpreter is the real one.
- **Times every sample alone**, subtracting the harness's own cost (an empty
  function measured the same way, after warm-up; ~1.5 us).
- **`setup` is untimed** (a fresh zombie per kill), and `batch` times N calls
  as one sample for calls too short to see.
- **Units, not microseconds, for budgets.** `Perf.unit()` is a fixed
  reference workload timed in the same process; `budgetUnits` divides by it,
  so a budget holds on a slower machine.
- **A-B-A for comparisons.** Whatever runs second comes out ~7% faster (the VM
  is still warming), so compare B against the mean of an A before and an A
  after.

## Wire cost: `mp-check.mjs`

A step in an MP scenario with `wire: { packets: N, bytes: B }` counts every
packet it sent across the Pass (the engine's own serialised bytes), reports
them by kind, and fails over budget. `wire: {}` just reports.

## Reading the numbers

- Medians are stable to a few percent run to run; p95 and max are not (GC,
  JIT, the OS). Budget the median; print the rest.
- An A/B delta smaller than the path's own run-to-run drift is noise: measure
  the added piece alone and budget that.
- Leave headroom (3-5x the measured median): a budget is for "a change made
  this several times more expensive", not for a few percent.
