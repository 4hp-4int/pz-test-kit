--[[
    Random rolls for the workbench.

    The kit's ZombRand/ZombRandFloat return the MIDPOINT, so tests are
    deterministic. That is right for a test suite and wrong for exploring:
    every affix roll, reroll and loot pick lands on the same answer. Mods call
    the globals at roll time (VPS: ZombRand(1, #candidates + 1)), so swapping
    the globals is enough.

    Modes:
      midpoint   the kit's own functions (tests' behaviour)
      seeded     Park-Miller PRNG from a seed: varied rolls, and the same
                 seed replays the same rolls (the Board resets the seed at the
                 start of every run all, so a blueprint replays exactly)
    PZ semantics: ZombRand(n) -> 0..n-1, ZombRand(min, max) -> min..max-1,
    ZombRandFloat(min, max) -> [min, max).

    Tools: setRandom{mode, seed}  getRandom{}
]]

WB.rng = WB.rng or { mode = "midpoint" }
if not WB.rng.mockZombRand then
    WB.rng.mockZombRand, WB.rng.mockZombRandFloat = ZombRand, ZombRandFloat
end

local M = 2147483647
local function nextUnit()
    -- 16807 * state < 2^46: exact in a double.
    WB.rng.state = (WB.rng.state * 16807) % M
    return WB.rng.state / M
end

local function seeded(seed)
    local s = math.floor(math.abs(tonumber(seed) or 1)) % M
    WB.rng.state = s == 0 and 1 or s
    WB.rng.rolls = 0
    ZombRand = function(a, b)
        WB.rng.rolls = WB.rng.rolls + 1
        local lo, hi = 0, a
        if b ~= nil then lo, hi = a, b end
        lo, hi = math.floor(lo or 0), math.floor(hi or 0)
        if hi <= lo then return lo end
        return lo + math.floor(nextUnit() * (hi - lo))
    end
    ZombRandFloat = function(a, b)
        WB.rng.rolls = WB.rng.rolls + 1
        a, b = a or 0, b or 1
        return a + nextUnit() * (b - a)
    end
end

WB.register("setRandom", function(a)
    local mode = (a and a.mode) or "seeded"
    if mode == "midpoint" then
        ZombRand, ZombRandFloat = WB.rng.mockZombRand, WB.rng.mockZombRandFloat
        WB.rng.mode, WB.rng.seed = "midpoint", nil
    else
        local seed = a and a.seed
        if seed == nil or seed == "" then seed = math.floor((_pz_now_ms and _pz_now_ms() or 1) % M) end
        seeded(seed)
        WB.rng.mode, WB.rng.seed = "seeded", tonumber(seed)
    end
    return { mode = WB.rng.mode, seed = WB.rng.seed }
end)

WB.register("getRandom", function()
    return { mode = WB.rng.mode, seed = WB.rng.seed, rolls = WB.rng.rolls }
end)
