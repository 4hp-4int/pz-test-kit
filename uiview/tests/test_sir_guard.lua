--[[
    SauceInvRender — fail-open guard (sir_guard.lua)
    ================================================
    The sustainability contract: a SIR surface that throws stands down and
    hands vanilla back. These tests drive the guard directly — wrap passthrough
    while healthy, trip-restore-fallback on error, idempotent manual trips.
]]

local Assert = PZTestKit.Assert

require "sir_guard"
local G = _G.SauceInvRender.Guard

local tests = {}

tests["wrap_passes_through_while_healthy"] = function()
    G.tripped["t_pass"] = nil
    local fn = G.wrap("t_pass", function(a, b) return a + b end)
    local sum = fn(2, 3)
    return Assert.equal(sum, 5, "healthy wrap returns the body's result")
        and Assert.isTrue(G.tripped["t_pass"] == nil, "no trip recorded")
end

tests["error_trips_once_restores_and_falls_back"] = function()
    G.tripped["t_boom"] = nil
    local restored, lastArg = false, nil
    local fn = G.wrap("t_boom",
        function() error("boom") end,
        function() restored = true end,
        function(a) lastArg = a; return "vanilla" end)
    local first = fn(7)
    local second = fn(9)
    return Assert.equal(first, "vanilla", "failing call falls through to vanilla")
        and Assert.isTrue(restored, "restore ran (vanilla reinstalled)")
        and Assert.isTrue(G.tripped["t_boom"] ~= nil, "surface marked tripped")
        and Assert.equal(second, "vanilla", "later calls skip straight to fallback")
        and Assert.equal(lastArg, 9, "fallback receives the call's args")
end

tests["manual_trip_is_idempotent_and_health_reflects"] = function()
    local before = G.healthy()
    G.trip("t_manual", "first")
    G.trip("t_manual", "second (must not overwrite)")
    local msg = G.tripped["t_manual"]
    G.tripped["t_manual"] = nil
    G.tripped["t_boom"] = nil
    G.tripped["t_pass"] = nil
    return Assert.isTrue(msg ~= nil and tostring(msg):find("first", 1, true) ~= nil,
        "first error message kept")
        and Assert.isTrue(before == false or before == true, "healthy() returns a boolean")
end

return tests
