--[[
    PZTestKit.Arena: headless one-way combat through the game's own hit
    pipeline (kahlua/arena.lua). These lock the behaviours that took a bug
    hunt each to get right (2026-10-06):
      - engine-fired events (OnHitZombie, OnZombieDead...) reach mod Lua
      - a hit lands damage (the LuaManager.getTableObject / Core.lastStand /
        getOptionUsePhysicsHitReaction stubs; Kahlua swallowed each Error)
      - the weapon is really in hand (GameEntityManager must be started, or
        setPrimaryHandItem silently does nothing and crit chance reads 0)
      - single-player mode knocks down on a crit; a broken weapon ends the fight
      - same seed, same fight (Lua ZombRand AND the engine's Rand are seeded)
]]
if not (PZTestKit.Arena and PZTestKit.Arena.available()) then return {} end
local Assert = PZTestKit.Assert
local tests = {}

local function fight(seed, swings, mode)
    local A = PZTestKit.Arena.new{ weapon = "Base.Axe", seed = seed, mode = mode }
    A:spawn(3)
    local s = A:fight{ swings = swings, keep = 3 }
    A:close()
    return s
end

tests["arena_kills_through_the_real_pipeline"] = function()
    local s = fight(7, 150)
    if not Assert.isTrue(s.deaths > 0, "zombies die") then return false end
    if not Assert.equal(s.kills, s.deaths, "every death reached Lua as OnZombieDead") then return false end
    if not Assert.equal(#s.errors, 0, "no engine errors: " .. table.concat(s.errors, "; ")) then return false end
    return Assert.equal(s.events.OnHitZombie, s.hits, "OnHitZombie once per hit")
end

tests["arena_weapon_in_hand_so_crits_roll"] = function()
    local s = fight(7, 150)
    return Assert.isTrue(s.crits > 0 and s.critChanceSum > 0, "crit chance read from the held weapon")
end

tests["arena_sp_crit_knocks_down"] = function()
    local s = fight(7, 150, "sp")
    return Assert.isTrue(s.knockdowns > 0 and s.knockdowns >= s.crits, "a crit knocks its targets down in single player")
end

tests["arena_wear_rolls_per_target_and_breaks"] = function()
    local s = fight(3, 2000)
    if not Assert.equal(s.wearRolls, s.hits, "one wear roll per target hit") then return false end
    return Assert.isTrue(s.broke and s.condition == 0, "the Axe wears out and the fight stops")
end

tests["arena_same_seed_same_fight"] = function()
    local a, b = fight(11, 80), fight(11, 80)
    local function key(s) return s.deaths .. "|" .. s.conditionLost .. "|" .. s.crits .. "|" .. string.format("%.4f", s.damage) end
    return Assert.equal(key(a), key(b), "replays exactly")
end

tests["arena_pistol_fires_reloads_and_is_heard"] = function()
    local A = PZTestKit.Arena.new{ weapon = "Base.Pistol", seed = 9 }
    A:spawn(3, { distance = 2 })
    local s = A:fight{ swings = 200, keep = 3, spawn = { distance = 2 } }
    local radius = A.weapon:getSoundRadius()
    A:close()
    if not Assert.equal(#s.errors, 0, "no engine errors: " .. table.concat(s.errors, "; ")) then return false end
    if not Assert.equal(s.ammoUsed, s.shots, "one round per shot") then return false end
    if not Assert.isTrue(s.reloads > 0 and s.deaths > 0, "it reloads and kills") then return false end
    if not Assert.isTrue(s.hitRate > 0.3 and s.hitRate < 0.8, "the game's to-hit chance decides hits (~50%): " .. tostring(s.hitRate)) then return false end
    return Assert.equal(s.soundRadiusMax, radius, "the shot is heard at the weapon's sound radius (outdoors)")
end

tests["arena_shotgun_hits_several_and_racks"] = function()
    local A = PZTestKit.Arena.new{ weapon = "Base.Shotgun", seed = 9 }
    A:spawn(3, { distance = 2 })
    local s = A:fight{ swings = 100, keep = 3, spawn = { distance = 2 } }
    A:close()
    return Assert.isTrue(s.shotHits > s.shots, "a shotgun blast hits more than one zombie")
end

return tests
