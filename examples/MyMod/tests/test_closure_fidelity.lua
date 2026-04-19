--[[
    Closure-mock fidelity tests
    =====================================
    Verify that `weapon._privateField = value` writes have NO effect on mock
    behavior — matching real PZ where such writes either throw or are ignored
    by the Java object. This is the exact pattern that failed VPS's 7
    magsm_* tests in-game while silently passing against plain-table mocks.
]]

local Assert = PZTestKit.Assert

local tests = {}

tests["private_field_write_does_not_affect_getter"] = function()
    local weapon = instanceItem("Base.Pistol")
    if not Assert.notNil(weapon, "spawn pistol") then return false end

    -- Assert initial state (from script data or default)
    local originalType = weapon:getMagazineType()

    -- The broken-test pattern: write to private field
    weapon._magazineType = "FORGED_VALUE"

    -- getMagazineType must still return the original, NOT "FORGED_VALUE"
    -- (In a plain-table mock, the write would win. In closure mock, it's inert.)
    return Assert.equal(weapon:getMagazineType(), originalType,
        "private field write is inert — getter reads closure state")
end

tests["private_containsClip_write_does_not_affect_isContainsClip"] = function()
    local weapon = instanceItem("Base.Pistol")
    if not Assert.notNil(weapon, "spawn pistol") then return false end

    local original = weapon:isContainsClip()

    -- Try to flip state via private-field write (this is what VPS's broken
    -- magsm tests did, relying on mock behavior that real PZ doesn't provide)
    weapon._containsClip = not original

    return Assert.equal(weapon:isContainsClip(), original,
        "isContainsClip ignores weapon._containsClip writes")
end

tests["method_override_DOES_work"] = function()
    local weapon = instanceItem("Base.Pistol")
    if not Assert.notNil(weapon, "spawn pistol") then return false end

    -- The CORRECT pattern: override the method (works in both mock and real PZ)
    weapon.isContainsClip = function() return true end

    return Assert.isTrue(weapon:isContainsClip(),
        "method override changes behavior as expected")
end

tests["method_override_getMagazineType"] = function()
    local weapon = instanceItem("Base.Pistol")
    if not Assert.notNil(weapon, "spawn pistol") then return false end

    weapon.getMagazineType = function() return "FakeType" end

    return Assert.equal(weapon:getMagazineType(), "FakeType",
        "getMagazineType override works")
end

return tests
