--[[ pal_history — frequency prior + repeat-last accelerator. Was 28% covered.
     Ranking contract: while typing, a recorded command gets a tiny tiebreak
     (min(8,n)*40); in zero-state the LAST-run command floats with +4000 ("." then
     Enter repeats it), and 8+ uses earns the 'frequent' habit tag. Pure logic over a
     flat file (getFileReader stubbed nil = empty; getFileWriter is a harness no-op). ]]
local Assert = PZTestKit.Assert
require "palette/pal_history"
local SP = _G.SaucePalette
local Hy = SP.History

local function noFile(fn)
    local saved = _G.getFileReader
    _G.getFileReader = function() return nil end
    local ok, err = pcall(fn)
    _G.getFileReader = saved
    if not ok then error(err) end
end

local tests = {}

tests["idOf_is_stable_kind_label_source"] = function()
    local cmd = { kind = "craft", label = "Saw Log", source = "craft" }
    local a = Hy.idOf(cmd)
    if not Assert.equal(a, "craft|Saw Log|craft", "id = kind|label|source") then return false end
    return Assert.equal(Hy.idOf(cmd), a, "the cached _hid returns the same id")
end

tests["frequency_boost_scales_while_typing"] = function()
    local cmd = { kind = "use", label = "Hist Freq A", source = "s" }
    local b0, b3
    noFile(function()
        b0 = (Hy.boostFor(cmd, true))            -- never recorded -> 0
        for _ = 1, 3 do Hy.record(cmd) end
        b3 = (Hy.boostFor(cmd, true))            -- 3 uses, typing -> min(8,3)*40
    end)
    if not Assert.equal(b0, 0, "an unrecorded command gets no frequency boost") then return false end
    return Assert.equal(b3, 120, "3 uses while typing -> 120")
end

tests["frequent_tag_at_eight_uses"] = function()
    local cmd = { kind = "use", label = "Hist Freq B", source = "s" }
    local rk
    noFile(function()
        for _ = 1, 8 do Hy.record(cmd) end
        rk = select(2, Hy.boostFor(cmd, true))
    end)
    return Assert.equal(rk, "frequent", "8+ uses earns the 'frequent' habit tag")
end

tests["repeat_last_floats_in_zero_state"] = function()
    local cmd = { kind = "use", label = "Hist Last", source = "s" }
    local b, rk
    noFile(function()
        Hy.record(cmd)                           -- becomes the last-run id
        b, rk = Hy.boostFor(cmd, false)          -- zero-state
    end)
    if not Assert.isTrue(b >= 4000, "the last-run command floats with +4000 in zero-state") then return false end
    return Assert.equal(rk, "last", "tagged 'last' (the repeat-last target)")
end

tests["getLast_returns_last_recorded_id"] = function()
    local cmd = { kind = "use", label = "Hist GetLast", source = "s" }
    local last
    noFile(function() Hy.record(cmd); last = Hy.getLast() end)
    return Assert.equal(last, "use|Hist GetLast|s", "getLast returns the last-run id")
end

return tests
