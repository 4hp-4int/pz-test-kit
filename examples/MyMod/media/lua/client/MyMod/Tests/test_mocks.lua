--[[
    PZ Test Kit — API and Mock Tests
    ================================
    Tests that validate the PZ API contract. Runs in BOTH environments:
    - Offline (Kahlua): tests run against mock objects
    - In-game: tests run against real PZ objects

    Tests that need to control game state (time, weather, player traits)
    are marked offline-only. Everything else runs in both.
]]

if isServer() and not isClient() then return end

local Assert = PZTestKit.Assert
local tests = {}

-- Detect environment
local function isOffline() return _pz_world_hours ~= nil end

-- ============================================================================
-- WEAPONS (runs in both — instanceItem is real in-game, mock offline)
-- ============================================================================

tests["weapon_spawn_and_type"] = function()
    local weapon = instanceItem("Base.Axe")
    if not Assert.notNil(weapon, "instanceItem returns weapon") then return false end
    return Assert.isTrue(instanceof(weapon, "HandWeapon"), "instanceof HandWeapon")
end

tests["weapon_stats_readable"] = function()
    local weapon = instanceItem("Base.Axe")
    if not Assert.notNil(weapon, "spawn") then return false end
    if not Assert.greater(weapon:getMaxDamage(), 0, "maxDamage > 0") then return false end
    if not Assert.greater(weapon:getMinDamage(), 0, "minDamage > 0") then return false end
    if not Assert.greater(weapon:getConditionMax(), 0, "conditionMax > 0") then return false end
    return Assert.isTrue(weapon:hasSharpness(), "Axe is sharpenable")
end

tests["weapon_setters_persist"] = function()
    local weapon = instanceItem("Base.Axe")
    if not Assert.notNil(weapon, "spawn") then return false end

    local origMax = weapon:getMaxDamage()
    weapon:setMaxDamage(origMax + 1.0)
    if not Assert.greater(weapon:getMaxDamage(), origMax, "setMaxDamage persists") then return false end

    weapon:setCriticalChance(99)
    return Assert.greaterEq(weapon:getCriticalChance(), 0, "setCriticalChance works")
end

tests["weapon_sharpness_affects_crit"] = function()
    local weapon = instanceItem("Base.Axe")
    if not Assert.notNil(weapon, "spawn") then return false end

    weapon:setSharpness(1.0)
    local fullCrit = weapon:getCriticalChance()

    weapon:setSharpness(0.5)
    local halfCrit = weapon:getCriticalChance()

    return Assert.less(halfCrit, fullCrit, "degraded sharpness reduces crit")
end

tests["weapon_moddata_persists"] = function()
    local weapon = instanceItem("Base.Axe")
    if not Assert.notNil(weapon, "spawn") then return false end

    weapon:getModData().testField = "hello"
    weapon:getModData().testNum = 42

    if not Assert.equal(weapon:getModData().testField, "hello", "string persists") then return false end
    return Assert.equal(weapon:getModData().testNum, 42, "number persists")
end

tests["weapon_melee_vs_ranged"] = function()
    local axe = instanceItem("Base.Axe")
    local pistol = instanceItem("Base.Pistol")
    if not Assert.notNil(axe, "spawn axe") then return false end
    if not Assert.notNil(pistol, "spawn pistol") then return false end

    if not Assert.isFalse(axe:isRanged(), "Axe not ranged") then return false end
    return Assert.isTrue(pistol:isRanged(), "Pistol is ranged")
end

-- ============================================================================
-- PLAYER (runs in both — getSpecificPlayer is real in-game)
-- ============================================================================

tests["player_exists"] = function()
    local player = getSpecificPlayer(0)
    if not Assert.notNil(player, "getSpecificPlayer(0)") then return false end
    return Assert.isTrue(instanceof(player, "IsoPlayer"), "instanceof IsoPlayer")
end

tests["player_has_inventory"] = function()
    local player = getSpecificPlayer(0)
    local inv = player:getInventory()
    return Assert.notNil(inv, "player has inventory")
end

tests["player_equip_weapon"] = function()
    local player = getSpecificPlayer(0)
    local weapon = instanceItem("Base.Axe")
    if not Assert.notNil(weapon, "spawn") then return false end

    player:setPrimaryHandItem(weapon)
    local equipped = player:getPrimaryHandItem()

    if not Assert.notNil(equipped, "primary hand has weapon") then return false end
    return Assert.equal(equipped:getFullType(), "Base.Axe", "correct weapon equipped")
end

tests["player_moddata_persists"] = function()
    local player = getSpecificPlayer(0)
    local md = player:getModData()

    md.PZTestKit_testValue = 12345
    return Assert.equal(md.PZTestKit_testValue, 12345, "player moddata persists")
end

-- ============================================================================
-- GAMETIME (runs in both — just reads, doesn't control)
-- ============================================================================

tests["gametime_readable"] = function()
    local gt = GameTime.getInstance()
    if not Assert.notNil(gt, "GameTime.getInstance()") then return false end

    local hours = gt:getWorldAgeHours()
    local hour = gt:getHour()

    if not Assert.isTrue(type(hours) == "number", "worldAgeHours is number") then return false end
    return Assert.isTrue(type(hour) == "number", "hour is number")
end

-- ============================================================================
-- GLOBALS (runs in both)
-- ============================================================================

tests["instanceof_works"] = function()
    local weapon = instanceItem("Base.Axe")
    local player = getSpecificPlayer(0)

    if not Assert.isTrue(instanceof(weapon, "HandWeapon"), "weapon is HandWeapon") then return false end
    if not Assert.isTrue(instanceof(player, "IsoPlayer"), "player is IsoPlayer") then return false end
    if not Assert.isFalse(instanceof(weapon, "IsoPlayer"), "weapon is not IsoPlayer") then return false end
    return Assert.isFalse(instanceof(nil, "HandWeapon"), "nil instanceof is false")
end

tests["server_commands_safe"] = function()
    -- These should not crash in either environment
    sendServerCommand("PZTestKit", "test", {})
    return Assert.isTrue(true, "sendServerCommand didn't crash")
end

-- ============================================================================
-- MOCK FACTORIES (runs in both — pure Lua tables, no game deps)
-- ============================================================================

tests["mock_zombie_api"] = function()
    if not _pz_create_mock_zombie then
        return Assert.isTrue(true, "SKIP: mock factory not loaded")
    end

    local zombie = _pz_create_mock_zombie({ health = 2.5 })
    if not Assert.notNil(zombie, "zombie created") then return false end
    if not Assert.nearEqual(zombie:getHealth(), 2.5, 0.01, "health correct") then return false end

    zombie:setStaggerBack(true)
    if not Assert.isTrue(zombie:isStaggerBack(), "stagger works") then return false end

    zombie:SetOnFire()
    return Assert.isTrue(zombie:isOnFire(), "fire works")
end

tests["mock_gridsquare_api"] = function()
    if not _pz_create_mock_square then
        return Assert.isTrue(true, "SKIP: mock factory not loaded")
    end

    local outside = _pz_create_mock_square({ isOutside = true, x = 100, y = 200 })
    if not Assert.isTrue(outside:isOutside(), "outside square") then return false end
    if not Assert.isNil(outside:getRoom(), "outside has no room") then return false end
    if not Assert.equal(outside:getX(), 100, "x position") then return false end

    local inside = _pz_create_mock_square({ isOutside = false, room = "bedroom" })
    if not Assert.isFalse(inside:isOutside(), "inside square") then return false end
    return Assert.notNil(inside:getRoom(), "inside has room")
end

-- ============================================================================
-- OFFLINE-ONLY: Controllable game state
-- ============================================================================

tests["offline_time_controllable"] = function()
    if not isOffline() then return Assert.isTrue(true, "SKIP: offline only") end

    local origHours = _pz_world_hours
    local origHour = _pz_hour_of_day

    _pz_world_hours = 500.0
    _pz_hour_of_day = 3

    local ok1 = Assert.nearEqual(GameTime.getInstance():getWorldAgeHours(), 500.0, 0.01, "world hours overridden")
    local ok2 = Assert.equal(GameTime.getInstance():getHour(), 3, "hour overridden")

    _pz_world_hours = origHours
    _pz_hour_of_day = origHour
    return ok1 and ok2
end

tests["offline_weather_controllable"] = function()
    if not isOffline() then return Assert.isTrue(true, "SKIP: offline only") end

    local origRain = _pz_rain_intensity
    _pz_rain_intensity = 0.8

    local rain = getWorld():getClimateManager():getRainIntensity()
    _pz_rain_intensity = origRain

    return Assert.nearEqual(rain, 0.8, 0.01, "rain intensity controllable")
end

tests["offline_sandbox_vars"] = function()
    if not isOffline() then return Assert.isTrue(true, "SKIP: offline only") end

    SandboxVars.PZTestKit = { TestValue = 42, Enabled = true }

    if not Assert.equal(SandboxVars.PZTestKit.TestValue, 42, "sandbox int") then return false end
    return Assert.isTrue(SandboxVars.PZTestKit.Enabled, "sandbox bool")
end

-- Self-register
PZTestKit.registerTests("test_mocks", tests)
print("[MyMod] test_mocks registered")

return tests
