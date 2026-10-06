--[[
    PZTestKit.Perf measures what it says (2026-10-06). Absolute timings vary
    by machine, so these check the instrument's behaviour, not a number:
    the clock is cheap, more work measures more, setup is untimed, and a
    batched sample agrees with single samples.
]]

if not (PZTestKit and PZTestKit.Perf and PZTestKit.Perf.available()) then return {} end
local Assert = PZTestKit.Assert
local Perf = PZTestKit.Perf

local function work(n)
    local x = 0
    for i = 1, n do x = x + i % 7 end
    return x
end

local tests = {}

tests["the_clock_costs_little"] = function()
    local oh = Perf.overhead()
    print(string.format("[perf] clock overhead %d ns", oh))
    return Assert.isTrue(oh >= 0 and oh < 5000, "two nanoTime reads under 5 us")
end

tests["a_hundred_times_the_work_measures_clearly_more"] = function()
    local small = Perf.measure("work 100", function() work(100) end, { runs = 300, warmup = 100 })
    local big = Perf.measure("work 10000", function() work(10000) end, { runs = 300, warmup = 100 })
    Perf.print(small); Perf.print(big)
    local c = Perf.compare("x100 work", small, big)
    Perf.print(c)
    return Assert.isTrue(c.ratio and c.ratio > 20, "x100 the work is over x20 the time (" .. tostring(c.ratio) .. ")")
end

tests["setup_is_not_timed"] = function()
    local r = Perf.measure("trivial after heavy setup", function(x) return x end,
        { runs = 300, warmup = 50, setup = function() return work(20000) end })
    local heavy = Perf.measure("the heavy setup itself", function() work(20000) end, { runs = 100, warmup = 20 })
    Perf.print(r); Perf.print(heavy)
    return Assert.isTrue(r.median_us * 20 < heavy.median_us, "the timed call is a small fraction of its setup")
end

tests["a_batched_sample_agrees_with_single_samples"] = function()
    local single = Perf.measure("work 1000 single", function() work(1000) end, { runs = 400, warmup = 100 })
    local batched = Perf.measure("work 1000 batched", function() work(1000) end, { runs = 40, warmup = 10, batch = 10 })
    Perf.print(single); Perf.print(batched)
    local ratio = batched.median_us / single.median_us
    return Assert.isTrue(ratio > 0.5 and ratio < 2, "within a factor of two (" .. string.format("%.2f", ratio) .. ")")
end

tests["memory_reports_bytes_per_call"] = function()
    local r = Perf.memory("a 50-entry table per call", function() local t = {} for i = 1, 50 do t[i] = i end return t end, { runs = 5000 })
    Perf.print(r)
    return Assert.isTrue(r.bytes_per_call >= 0, "a number of bytes")
end

return tests
