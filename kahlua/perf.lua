--[[
    PZTestKit.Perf -- what a mod's Lua costs, on the game's own interpreter.

    SousVide runs PZ's Kahlua VM and the real game classes, so the cost of a
    mod's handler here is the cost of the same Lua there: per call, per kill,
    per tick, per minute, and how it scales. What it is NOT: frame time, render
    cost, the game's GC pauses or network latency. Read the numbers as
    RELATIVE (A against B on the same seed, budgets with headroom), not as
    the milliseconds a player's frame will lose.

    Method:
      - warm-up runs first (the JVM compiles hot paths; early samples lie)
      - every sample timed alone with PZEngine.nanoTime, the clock's own cost
        (two back-to-back reads) measured and subtracted
      - `setup` runs before each sample, untimed (a fresh zombie for a kill)
      - `batch` times N calls as one sample, for calls too short to see
      - reported in microseconds: median, p95, mean, min, max

      local r = Perf.measure("recordKill", function(w, p, z) Life.recordKill(w, p, z, d) end,
                             { runs = 500, warmup = 100, setup = function(i) return w, p, newZombie() end })
      Perf.budget(r, "median_us", 50)          -- true/false + a message
      Perf.compare("kill path", off, on)       -- the delta and ratio of medians
      Perf.memory("pack", fn, { runs = 2000 }) -- bytes per call, coarse

    Every result also lands in Perf.results, so a test can print a table.
]]

PZTestKit = PZTestKit or {}
local Perf = {}
PZTestKit.Perf = Perf
Perf.results = {}

function Perf.available()
    return PZEngine ~= nil and PZEngine.nanoTime ~= nil
end

local unpackFn = unpack or table.unpack
local function now() return PZEngine.nanoTime() end

-- ---------------------------------------------------------------------------
-- warming the VM
-- ---------------------------------------------------------------------------
-- The JVM compiles Kahlua's interpreter loop in tiers. Measured 2026-10-06: a
-- 100-iteration Lua loop ran at ~7 us for the first ~9000 calls, then at
-- ~2.8 us once the loop reached full compilation. The compiled code is the
-- INTERPRETER, shared by all Lua, so the whole VM is warmed once per process
-- with a mixed workload (arithmetic, tables, calls, strings, Java methods)
-- until a reference loop stops improving. The game runs for hours: the warm
-- interpreter is the one players have.
local warmed = false
local function refLoop() local x = 0 for i = 1, 100 do x = x + i end return x end
local function mixed()
    local t = {}
    for i = 1, 40 do t[i] = i * 1.5 end
    local s = 0
    for _, v in ipairs(t) do s = s + v % 3 end
    local str = string.format("%d:%s", s, "k") .. tostring(#t)
    local k = string.sub(str, 1, 3)
    local o = { a = 1, b = k }
    for kk, vv in pairs(o) do s = s + #tostring(kk) + (type(vv) == "number" and vv or 0) end
    return s + PZEngine.nanoTime() % 2
end
local function windowMedian(n)
    local xs = {}
    for i = 1, n do local t0 = now(); refLoop(); xs[i] = now() - t0 end
    table.sort(xs)
    return xs[math.floor(n / 2) + 1]
end

--- Warm the interpreter until the reference loop stops improving (at least
--- 20000 rounds, at most maxSeconds). Returns the trace of window medians.
function Perf.warmVM(maxSeconds)
    if warmed then return Perf.warmTrace end
    local deadline = now() + (maxSeconds or 6) * 1e9
    local trace, best, flat, rounds = {}, math.huge, 0, 0
    while now() < deadline do
        for _ = 1, 1000 do mixed(); refLoop() end
        rounds = rounds + 1000
        local m = windowMedian(500)
        trace[#trace + 1] = m
        if m < best * 0.97 then best = m; flat = 0 else flat = flat + 1 end
        if rounds >= 20000 and flat >= 5 then break end
    end
    warmed = true
    Perf.warmTrace = trace
    return trace
end

local overheadNs
--- The harness's own cost per sample (ns): an empty function measured the
--- same way samples are taken, after the VM is warm. Subtracted from every
--- sample, so a result is the function's cost, not the clock's or the loop's.
function Perf.overhead()
    if overheadNs then return overheadNs end
    Perf.warmVM()
    local empty = function() end
    local xs = {}
    for i = 1, 3000 do
        local t0 = now()
        empty()
        local t1 = now()
        xs[i] = t1 - t0
    end
    table.sort(xs)
    overheadNs = xs[math.floor(#xs / 2) + 1]
    return overheadNs
end

local function round(x, d)
    local m = 10 ^ (d or 2)
    return math.floor(x * m + 0.5) / m
end

local function summarise(xs)
    table.sort(xs)
    local n = #xs
    local sum = 0
    for i = 1, n do sum = sum + xs[i] end
    local function q(p) return xs[math.max(1, math.min(n, math.floor(p * n + 0.5)))] end
    return { n = n, min = xs[1], median = xs[math.floor(n / 2) + 1], p95 = q(0.95), p99 = q(0.99),
             mean = sum / n, max = xs[n] }
end
Perf._summarise = summarise

--- Time fn. opts: runs (1000), warmup (100), batch (1), setup(i) -> args.
function Perf.measure(name, fn, opts)
    opts = opts or {}
    local runs, warm, batch = opts.runs or 1000, opts.warmup or 300, math.max(1, opts.batch or 1)
    local setup = opts.setup
    local oh = Perf.overhead()   -- warms the VM first
    local empty = {}
    for i = 1, warm do
        local args = setup and { setup(i) } or empty
        for _ = 1, batch do fn(unpackFn(args)) end
    end
    local xs = {}
    for i = 1, runs do
        local t0, t1
        if setup then
            local args = { setup(warm + i) }
            t0 = now()
            for _ = 1, batch do fn(unpackFn(args)) end
            t1 = now()
        elseif batch == 1 then
            t0 = now(); fn(); t1 = now()
        else
            t0 = now()
            for _ = 1, batch do fn() end
            t1 = now()
        end
        xs[i] = math.max(0, t1 - t0 - oh) / batch
    end
    local s = summarise(xs)
    local r = { name = name, runs = runs, batch = batch, warmup = warm,
                median_us = round(s.median / 1000, 3), p95_us = round(s.p95 / 1000, 3), p99_us = round(s.p99 / 1000, 3),
                mean_us = round(s.mean / 1000, 3), min_us = round(s.min / 1000, 3), max_us = round(s.max / 1000, 3) }
    Perf.results[#Perf.results + 1] = r
    return r
end

--- Two measurements of the same thing (A then B): the delta and the ratio.
function Perf.compare(name, a, b)
    local c = { name = name, a = a.name, b = b.name,
                a_median_us = a.median_us, b_median_us = b.median_us,
                delta_us = round(b.median_us - a.median_us, 3),
                ratio = a.median_us > 0 and round(b.median_us / a.median_us, 3) or nil,
                delta_p95_us = round(b.p95_us - a.p95_us, 3) }
    return c
end

-- ---------------------------------------------------------------------------
-- machine-independent budgets
-- ---------------------------------------------------------------------------
-- Microseconds differ by machine. A UNIT is the median of a fixed reference
-- workload (the warm-up's mixed Lua, ten times) measured in the same process,
-- so a budget written in units holds on a slower machine too: the code under
-- test and the unit slow down together.
local unitUs
function Perf.unit()
    if unitUs then return unitUs end
    local r = Perf.measure("reference unit (mixed Lua x10)", function() for _ = 1, 10 do mixed() end end, { runs = 600, warmup = 200 })
    unitUs = r.median_us
    return unitUs
end

function Perf.inUnits(r, field)
    return r[field or "median_us"] / Perf.unit()
end

--- Is r[field] within `units` reference units? Returns ok, message.
function Perf.budgetUnits(r, field, units)
    local u = Perf.inUnits(r, field)
    local ok = u <= units
    return ok, string.format("%s %s = %.2f units (%.3f us; 1 unit = %.3f us), budget %s units",
        r.name or "?", field, u, r[field], Perf.unit(), tostring(units))
end

--- Is r[field] within budget? Returns ok, message.
function Perf.budget(r, field, limit)
    local v = r[field]
    local ok = v ~= nil and v <= limit
    return ok, string.format("%s %s = %s (budget %s)", r.name or "?", field, tostring(v), tostring(limit))
end

--- Heap bytes per call, after a collection. Coarse: the JVM decides when to
--- collect, so treat it as an estimate, and use many runs.
function Perf.memory(name, fn, opts)
    opts = opts or {}
    local runs = opts.runs or 2000
    for _ = 1, math.min(200, runs) do fn() end
    PZEngine.gc()
    local m0 = PZEngine.memUsed()
    for _ = 1, runs do fn() end
    local m1 = PZEngine.memUsed()
    local r = { name = name, runs = runs, bytes_per_call = round(math.max(0, m1 - m0) / runs, 1) }
    Perf.results[#Perf.results + 1] = r
    return r
end

function Perf.format(r)
    if r.bytes_per_call then return string.format("%-40s %8.1f bytes/call (%d runs)", r.name, r.bytes_per_call, r.runs) end
    if r.delta_us then
        return string.format("%-40s %s %.3f us -> %s %.3f us: +%.3f us (x%s), p95 +%.3f us",
            r.name, r.a, r.a_median_us, r.b, r.b_median_us, r.delta_us, tostring(r.ratio), r.delta_p95_us)
    end
    return string.format("%-40s median %9.3f us  p95 %9.3f us  mean %9.3f us  min %8.3f  max %9.3f  (%d x %d)",
        r.name, r.median_us, r.p95_us, r.mean_us, r.min_us, r.max_us, r.runs, r.batch)
end

function Perf.print(r) print("[perf] " .. Perf.format(r)) end

return Perf
