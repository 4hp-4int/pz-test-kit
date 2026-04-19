--[[
    Tier 4 smoke tests:
      - PZTestKit.Fixtures.weapon / .firearm / .zombie
      - PZTestKit.SKIP / PZTestKit.skip("reason")
      - dual-VM syncHandWeaponFields / syncItemFields replication
]]

local Assert   = PZTestKit.Assert
local Fixtures = PZTestKit.Fixtures
local tests    = {}

-- ── Fixtures.weapon ────────────────────────────────────────────────────────

tests["fixture_weapon_defaults"] = function()
    local w = Fixtures.weapon()
    if not Assert.notNil(w, "weapon created") then return false end
    if not Assert.isTrue(w:IsWeapon(), "IsWeapon true") then return false end
    return Assert.isFalse(w:isRanged(), "not ranged by default")
end

tests["fixture_weapon_opts_override"] = function()
    local w = Fixtures.weapon({ maxDamage = 3.5, conditionMax = 20 })
    if not Assert.equal(w:getMaxDamage(), 3.5, "maxDamage from opts") then return false end
    return Assert.equal(w:getConditionMax(), 20, "conditionMax from opts")
end

tests["fixture_firearm_preset"] = function()
    local f = Fixtures.firearm()
    if not Assert.isTrue(f:isRanged(), "firearm is ranged") then return false end
    return Assert.greater(f:getClipSize(), 0, "firearm has a clip")
end

-- ── Fixtures.zombie — methods verified against IsoZombie.java ─────────────

tests["fixture_zombie_health_and_death"] = function()
    local z = Fixtures.zombie({ health = 2.0 })
    if not Assert.equal(z:getHealth(), 2.0, "initial health") then return false end
    if not Assert.isTrue(z:isAlive(), "alive while health > 0") then return false end
    z:setHealth(0)
    if not Assert.equal(z:getHealth(), 0, "health set to 0") then return false end
    return Assert.isFalse(z:isAlive(), "dead at health 0")
end

tests["fixture_zombie_stagger_and_fire"] = function()
    local z = Fixtures.zombie()
    if not Assert.isFalse(z:isStaggerBack(), "not staggered by default") then return false end
    z:setStaggerBack(true)
    if not Assert.isTrue(z:isStaggerBack(), "staggered after set") then return false end
    z:SetOnFire()
    return Assert.isTrue(z:isOnFire(), "on fire after SetOnFire")
end

-- ── SKIP marker ───────────────────────────────────────────────────────────

tests["skip_marker_is_honored"] = function()
    return PZTestKit.skip("intentional skip for test infrastructure check")
end

-- ── Dual-VM: field sync via syncHandWeaponFields ──────────────────────────

tests["syncHandWeaponFields_replicates_stats"] = function()
    local sim = PZTestKit.Sim.new({ players = 1 })
    sim:spawnSyncedWeapon("Base.Pistol", { id = 501 })

    -- Server mutates firearm stats and calls the real sync function
    sim.server:exec([[
        _wpn:setClipSize(30)
        _wpn:setRecoilDelay(20)
        _wpn:setMaxDamage(1.2)
        syncHandWeaponFields(getPlayer(), _wpn)
    ]])
    sim:flush()

    local clipSize    = sim.clients[1]:eval("return _wpn:getClipSize()")
    local recoilDelay = sim.clients[1]:eval("return _wpn:getRecoilDelay()")
    local maxDamage   = sim.clients[1]:eval("return _wpn:getMaxDamage()")

    if not Assert.equal(clipSize, 30, "clipSize replicated") then return false end
    if not Assert.equal(recoilDelay, 20, "recoilDelay replicated") then return false end
    return Assert.nearEqual(maxDamage, 1.2, 0.001, "maxDamage replicated")
end

tests["syncItemFields_replicates_condition"] = function()
    local sim = PZTestKit.Sim.new({ players = 1 })
    sim:spawnSyncedWeapon("Base.Axe", { id = 502 })

    sim.server:exec([[
        _wpn:setCondition(3)
        syncItemFields(getPlayer(), _wpn)
    ]])
    sim:flush()

    local cond = sim.clients[1]:eval("return _wpn:getCondition()")
    return Assert.equal(cond, 3, "condition replicated to client")
end

return tests
