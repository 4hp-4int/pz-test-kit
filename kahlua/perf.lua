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
-- Java method calls from Lua go through Kahlua's invoker machinery, also
-- shared and also JIT-compiled late: measured, a path making three Java calls
-- ran ~10x slower for its first ~5000-8000 calls. The warm-up makes Java
-- calls on real objects (an ArrayList, a real item when the engine has one).
local jlist, jitem
local function javaCalls()
    if jlist == nil then
        jlist = (ArrayList and ArrayList.new and ArrayList.new()) or false
        jitem = (type(instanceItem) == "function" and instanceItem("Base.Axe")) or false
        if jlist then jlist:add(1) end
    end
    local n = 0
    if jlist then n = n + jlist:size() + (jlist:get(0) or 0) end
    if jitem then
        local md = jitem:getModData()
        n = n + jitem:getID() % 2 + jitem:getCondition() + (md and 0 or 1)
    end
    return n
end

local function mixed()
    local t = {}
    for i = 1, 40 do t[i] = i * 1.5 end
    local s = 0
    for _, v in ipairs(t) do s = s + v % 3 end
    local str = string.format("%d:%s", s, "k") .. tostring(#t)
    local k = string.sub(str, 1, 3)
    local o = { a = 1, b = k }
    for kk, vv in pairs(o) do s = s + #tostring(kk) + (type(vv) == "number" and vv or 0) end
    return s + PZEngine.nanoTime() % 2 + javaCalls()
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
    local runs, warm, batch = opts.runs or 1000, opts.warmup or 2000, math.max(1, opts.batch or 1)
    local setup = opts.setup
    local oh = Perf.overhead()   -- warms the VM first
    local empty = {}
    local function once(i)
        local args = setup and { setup(i) } or empty
        local t0 = now()
        for _ = 1, batch do fn(unpackFn(args)) end
        return now() - t0
    end
    -- Each code path warms on its own too: measured, getModData sat on a flat
    -- ~34 us plateau for its first ~3000 calls, then dropped to 3.7 us, in an
    -- already-warm VM. A "stopped improving" rule cannot see a drop that has
    -- not happened yet, so the minimum is large (2000 calls, bounded by time
    -- for expensive work), then windows continue until 3 flat ones.
    local deadline = now() + (opts.maxWarmSeconds or 4) * 1e9
    local i = 0
    while i < warm and now() < deadline do i = i + 1; once(i) end
    local done, best, flat = i, math.huge, 0
    local maxCalls = opts.maxWarmup or 8000
    while opts.adaptive ~= false and done < maxCalls and now() < deadline do
        local xs = {}
        for k = 1, 100 do i = i + 1; xs[k] = once(i) end
        table.sort(xs)
        local m = xs[51]
        done = done + 100
        if m < best * 0.97 then best = m; flat = 0 else flat = flat + 1 end
        if flat >= 3 then break end
    end
    warm = done
    -- SETTLE: measure in rounds of `runs` samples and report the first round
    -- whose median agrees with the round before it within 5% (at most
    -- opts.rounds, default 4). Warm-up thresholds differ by path and cannot
    -- be predicted (measured: one sat on a 34 us plateau for ~5000-8000 calls
    -- before running at 3.7 us), but a settled state can be detected.
    local function round1(base)
        local xs = {}
        for k = 1, runs do
            local t0, t1
            if setup then
                local args = { setup(base + k) }
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
            xs[k] = math.max(0, t1 - t0 - oh) / batch
        end
        return xs
    end
    local maxRounds = (opts.settle == false) and 1 or (opts.rounds or 4)
    local xs, prev, rounds = nil, nil, 0
    for k = 1, maxRounds do
        xs = round1(warm + (k - 1) * runs)
        rounds = k
        table.sort(xs)
        local m = xs[math.floor(#xs / 2) + 1]
        if prev and math.abs(m - prev) <= 0.05 * math.max(prev, 1) then break end
        prev = m
    end
    local s = summarise(xs)
    local r = { name = name, runs = runs, batch = batch, warmup = warm, rounds = rounds,
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

-- ---------------------------------------------------------------------------
-- where the time goes: a function-level profiler
-- ---------------------------------------------------------------------------
-- local P = Perf.profiler()
-- P:wrap(WeaponData, "incrementKills")             -- a module function
-- P:wrap(_G, "syncItemModData", "net: syncItemModData")
-- P:wrapListeners(ModEvents.OnWeaponKillCredit, "kill credit")  -- an EventBus
-- P:start(); ...run the workload N times...; P:stop()   -- stop restores everything
-- P:report(N)   -- per wrapped function: calls, inclusive and SELF us per unit
-- Self time = inclusive minus the wrapped functions it called, so the column
-- adds up to the root's total. Only calls through the table are seen: code
-- holding the function in a local at load time bypasses the wrapper.
local Profiler = {}
Profiler.__index = Profiler

function Perf.profiler()
    return setmetatable({ rows = {}, order = {}, undo = {}, stack = {}, on = false }, Profiler)
end

function Profiler:row(label)
    local r = self.rows[label]
    if not r then
        r = { label = label, calls = 0, incl = 0, self = 0 }
        self.rows[label] = r
        self.order[#self.order + 1] = label
    end
    return r
end

-- records the sample and returns EVERY value the wrapped function returned
-- (a fixed a, b, c, d truncated longer returns and broke a VPS listener)
local function finish(P, row, frame, t0, ...)
    local dt = now() - t0
    local st = P.stack
    st[#st] = nil
    local parent = st[#st]
    if parent then parent.child = parent.child + dt end
    row.calls = row.calls + 1
    row.incl = row.incl + dt
    row.self = row.self + (dt - frame.child)
    return ...
end

function Profiler:timed(label, fn)
    local P = self
    local row = self:row(label)
    return function(...)
        if not P.on then return fn(...) end
        local frame = { child = 0 }
        local st = P.stack
        st[#st + 1] = frame
        return finish(P, row, frame, now(), fn(...))
    end
end

function Profiler:wrap(tbl, key, label)
    local fn = tbl and tbl[key]
    if type(fn) ~= "function" then return false end
    label = label or key
    tbl[key] = self:timed(label, fn)
    self.undo[#self.undo + 1] = function() tbl[key] = fn end
    return true
end

--- Every listener of a VorpallySauced-style EventBus (bus.listeners[i].callback).
function Profiler:wrapListeners(bus, prefix)
    if not (bus and bus.listeners) then return 0 end
    local n = 0
    for i, entry in ipairs(bus.listeners) do
        local cb = entry.callback
        entry.callback = self:timed(string.format("%s #%d (priority %s)", prefix, i, tostring(entry.priority)), cb)
        self.undo[#self.undo + 1] = function() entry.callback = cb end
        n = n + 1
    end
    return n
end

function Profiler:start() self.on = true end
function Profiler:stop()
    self.on = false
    for i = #self.undo, 1, -1 do self.undo[i]() end
    self.undo = {}
end

--- Rows sorted by self time, in microseconds per unit of work (n units).
function Profiler:report(n)
    n = math.max(1, n or 1)
    local out = {}
    for _, label in ipairs(self.order) do
        local r = self.rows[label]
        out[#out + 1] = { label = label, calls = r.calls / n, incl_us = round(r.incl / 1000 / n, 2), self_us = round(r.self / 1000 / n, 2) }
    end
    table.sort(out, function(x, y) return x.self_us > y.self_us end)
    return out
end

--- What wrapping costs per call (us): a wrapped no-op against a bare one.
local wrapOverheadUs
function Perf.profilerOverhead()
    if wrapOverheadUs then return wrapOverheadUs end
    Perf.warmVM()
    local P = Perf.profiler()
    local noop = function() end
    local wrapped = P:timed("noop", noop)
    P.on = true
    local N = 20000
    local t0 = now(); for _ = 1, N do noop() end; local t1 = now()
    for _ = 1, N do wrapped() end
    local t2 = now()
    wrapOverheadUs = round(math.max(0, (t2 - t1) - (t1 - t0)) / N / 1000, 3)
    return wrapOverheadUs
end

function Profiler:print(n, title)
    print("[perf] " .. (title or "profile") .. " (per unit of work):")
    print(string.format("[perf]   (each wrapped call adds ~%.2f us of profiler overhead: absolute times are inflated,"
        .. " the ranking is the finding; confirm with Perf.measure on the unwrapped code)", Perf.profilerOverhead()))
    print(string.format("[perf]   %-58s %7s %10s %10s", "function", "calls", "incl us", "self us"))
    for _, r in ipairs(self:report(n)) do
        print(string.format("[perf]   %-58s %7.2f %10.2f %10.2f", r.label, r.calls, r.incl_us, r.self_us))
    end
end

function Perf.format(r)
    if r.bytes_per_call then return string.format("%-40s %8.1f bytes/call (%d runs)", r.name, r.bytes_per_call, r.runs) end
    if r.delta_us then
        return string.format("%-40s %s %.3f us -> %s %.3f us: +%.3f us (x%s), p95 +%.3f us",
            r.name, r.a, r.a_median_us, r.b, r.b_median_us, r.delta_us, tostring(r.ratio), r.delta_p95_us)
    end
    return string.format("%-40s median %9.3f us  p95 %9.3f us  mean %9.3f us  min %8.3f  max %9.3f  (%d x %d, %s round%s)",
        r.name, r.median_us, r.p95_us, r.mean_us, r.min_us, r.max_us, r.runs, r.batch, tostring(r.rounds or 1), (r.rounds or 1) == 1 and "" or "s")
end

function Perf.print(r) print("[perf] " .. Perf.format(r)) end

return Perf
