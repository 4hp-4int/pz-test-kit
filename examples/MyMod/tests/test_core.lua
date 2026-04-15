-- Example test file for MyMod using PZ Test Kit
local Assert = PZTestKit.Assert

-- ============================================================================
-- VALIDATION TESTS
-- ============================================================================

local tests = {}

tests["mymod_validates_melee_weapon"] = function()
    local weapon = instanceItem("Base.Axe")
    if not Assert.notNil(weapon, "spawn Axe") then return false end
    return Assert.isTrue(MyMod.isValidWeapon(weapon), "Axe is valid melee")
end

tests["mymod_rejects_nil"] = function()
    return Assert.isFalse(MyMod.isValidWeapon(nil), "nil rejected")
end

tests["mymod_rejects_ranged"] = function()
    local weapon = instanceItem("Base.Pistol")
    if not Assert.notNil(weapon, "spawn Pistol") then return false end
    return Assert.isFalse(MyMod.isValidWeapon(weapon), "Pistol rejected as melee")
end

-- ============================================================================
-- BUFF AMOUNT TESTS
-- ============================================================================

tests["mymod_buff_zero_at_low_kills"] = function()
    return Assert.equal(MyMod.getBuffAmount(5), 0, "5 kills = no buff")
end

tests["mymod_buff_tier1_at_10_kills"] = function()
    return Assert.nearEqual(MyMod.getBuffAmount(10), 0.1, 0.001, "10 kills = 0.1 buff")
end

tests["mymod_buff_tier2_at_50_kills"] = function()
    return Assert.nearEqual(MyMod.getBuffAmount(50), 0.3, 0.001, "50 kills = 0.3 buff")
end

tests["mymod_buff_tier3_at_100_kills"] = function()
    return Assert.nearEqual(MyMod.getBuffAmount(100), 0.5, 0.001, "100 kills = 0.5 buff")
end

-- ============================================================================
-- DAMAGE APPLICATION TESTS
-- ============================================================================

tests["mymod_apply_damage_buff"] = function()
    local weapon = instanceItem("Base.Axe")
    if not Assert.notNil(weapon, "spawn Axe") then return false end
    local origMax = weapon:getMaxDamage()
    local origMin = weapon:getMinDamage()

    MyMod.applyDamageBuff(weapon, 0.3)

    if not Assert.nearEqual(weapon:getMaxDamage(), origMax + 0.3, 0.01, "maxDmg +0.3") then return false end
    return Assert.nearEqual(weapon:getMinDamage(), origMin + 0.3, 0.01, "minDmg +0.3")
end

tests["mymod_apply_buff_rejects_nil"] = function()
    return Assert.isFalse(MyMod.applyDamageBuff(nil, 0.5), "nil weapon rejected")
end

tests["mymod_apply_buff_rejects_ranged"] = function()
    local weapon = instanceItem("Base.Pistol")
    if not Assert.notNil(weapon, "spawn Pistol") then return false end
    return Assert.isFalse(MyMod.applyDamageBuff(weapon, 0.5), "ranged weapon rejected")
end

return tests
