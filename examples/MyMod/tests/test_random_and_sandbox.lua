--[[
    Two harness traps from one bug hunt (2026-10-05, VPS affix gates):
      - ZombRand is the MIDPOINT, so a test that samples rolls sees one
        outcome. PZTestKit.Random.seeded(n) gives real, replayable rolls and
        the executor undoes it after every test.
      - A running game changes sandbox options with no Lua event (an admin's
        edit: GameServer.receiveSandboxOptions). PZEngine.sandboxApply does
        what that path does -- typed set, applySettings -- and mirrors what
        the engine kept into SandboxVars.
]]

local Assert = PZTestKit.Assert
local tests = {}

tests["a_random_midpoint_is_the_default"] = function()
    if not Assert.equal(PZTestKit.Random.mode, "midpoint", "midpoint by default") then return false end
    return Assert.equal(ZombRand(1, 10), 5, "ZombRand(1,10) is the midpoint")
end

tests["b_random_seeded_varies_replays_and_keeps_pz_ranges"] = function()
    PZTestKit.Random.seeded(42)
    local first, seen, inRange = {}, {}, true
    for i = 1, 200 do
        local v = ZombRand(1, 10)              -- 1..9
        first[i] = v; seen[v] = true
        if v < 1 or v > 9 then inRange = false end
        local z = ZombRand(5)                  -- 0..4
        if z < 0 or z > 4 then inRange = false end
        local f = ZombRandFloat(2, 3)          -- [2,3)
        if f < 2 or f >= 3 then inRange = false end
    end
    local distinct = 0
    for _ in pairs(seen) do distinct = distinct + 1 end
    if not Assert.isTrue(inRange, "PZ ranges: max exclusive") then return false end
    if not Assert.isTrue(distinct >= 8, "rolls vary (" .. distinct .. " distinct of 9)") then return false end
    PZTestKit.Random.seeded(42)
    for i = 1, 200 do
        local v = ZombRand(1, 10)
        if v ~= first[i] then return Assert.isTrue(false, "same seed replays (diverged at " .. i .. ")") end
        ZombRand(5); ZombRandFloat(2, 3)
    end
    return true
end

tests["c_random_seeding_never_leaks_into_the_next_test"] = function()
    if not Assert.equal(PZTestKit.Random.mode, "midpoint", "back to midpoint") then return false end
    return Assert.equal(ZombRand(1, 10), 5, "midpoint again after a seeded test")
end

tests["d_random_midpoint_counts_repeated_calls_for_the_note"] = function()
    for _ = 1, 150 do ZombRand(1, 37) end   -- the executor prints a note for this test
    return Assert.equal(PZTestKit._randCalls["1,37"], 150, "repeated identical midpoint calls are counted")
end

if PZEngine and PZEngine.available() then
    tests["e_sandbox_apply_sets_applies_and_mirrors"] = function()
        local kept = PZEngine.sandboxApply({ MultiHitZombies = true, FuelStationGasEmptyChance = 55 })
        if not Assert.equal(kept.MultiHitZombies, true, "engine kept the boolean") then return false end
        if not Assert.equal(kept.FuelStationGasEmptyChance, 55, "engine kept the integer") then return false end
        if not Assert.equal(SandboxVars.MultiHitZombies, true, "mirrored into SandboxVars") then return false end
        if not Assert.equal(SandboxVars.FuelStationGasEmptyChance, 55, "integer mirrored") then return false end
        PZEngine.sandboxApply({ MultiHitZombies = false, FuelStationGasEmptyChance = 20 })
        return true
    end

    tests["f_sandbox_apply_mirrors_what_the_engine_kept_not_what_was_asked"] = function()
        PZEngine.sandboxApply({ FuelStationGasEmptyChance = 30 })
        local kept = PZEngine.sandboxApply({ FuelStationGasEmptyChance = 500, NoSuchOption = 1 })   -- range 0..100
        if not Assert.equal(kept.FuelStationGasEmptyChance, 30, "out of range: the engine refuses, old value stays") then return false end
        if not Assert.equal(SandboxVars.FuelStationGasEmptyChance, 30, "and the mirror shows the kept value") then return false end
        if not Assert.equal(kept.NoSuchOption, false, "an unknown option reports false") then return false end
        PZEngine.sandboxApply({ FuelStationGasEmptyChance = 20 })
        return true
    end
end

return tests
