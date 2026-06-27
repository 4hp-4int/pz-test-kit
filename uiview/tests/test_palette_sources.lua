--[[ pal_main source gates + MP pause safety.
     These require the FULL mod (pal_main pulls every provider + pal_ui), so they
     live apart from the lightweight States.build integration tests (test_palette_api)
     — loading the whole mod into that harness destabilizes its fake render env. ]]
local Assert = PZTestKit.Assert
require "palette/pal_main"
local SP = _G.SaucePalette

local tests = {}

-- ── source heavy / enabled flags ────────────────────────────────────────────
tests["source_heavy_flag"] = function()
    if not Assert.isTrue(SP.sourceHeavy({ id = "x", heavy = true }) == true, "heavy=true -> heavy tier") then return false end
    if not Assert.isTrue(SP.sourceHeavy({ id = "x", heavy = false }) == false, "heavy=false -> light tier") then return false end
    -- a built-in id with no explicit flag falls back to the HEAVY map
    if not Assert.isTrue(SP.sourceHeavy({ id = "world" }) == true, "built-in 'world' is heavy by default") then return false end
    return Assert.isTrue(SP.sourceHeavy({ id = "addon_unknown" }) == false, "unknown addon source defaults light")
end

tests["source_enabled_flag"] = function()
    if not Assert.isTrue(SP.sourceEnabled({ id = "x" }) == true, "default enabled") then return false end
    return Assert.isTrue(SP.sourceEnabled({ id = "x", enabled = false }) == false, "enabled=false -> off")
end

-- ── MP safety: pause only in true single-player ─────────────────────────────
tests["can_pause_only_in_singleplayer"] = function()
    local pc, ps = _G.isClient, _G.isServer
    _G.isClient = function() return false end; _G.isServer = function() return false end
    local sp = SP.canPause()
    _G.isClient = function() return true end;  _G.isServer = function() return false end
    local mpClient = SP.canPause()
    _G.isClient = function() return false end; _G.isServer = function() return true end
    local host = SP.canPause()
    _G.isClient, _G.isServer = pc, ps
    if not Assert.isTrue(sp == true, "true single-player -> can pause") then return false end
    if not Assert.isTrue(mpClient == false, "MP client -> never pauses") then return false end
    return Assert.isTrue(host == false, "co-op host -> never pauses (would freeze everyone)")
end

return tests
