--[[
    PZ Test Kit — Mock PZ Environment
    ==================================
    Provides mock implementations of PZ's Lua-exposed Java APIs.
    Load this before loading your mod's Lua files.

    Mocked: player, inventory, weapons, items, globals, events, sandbox,
            GameTime, ISTimedActionQueue, sendServerCommand, etc.

    To add your own mocks, just set fields on the tables after loading:
        _pz_player.getUsername = function(self) return "TestPlayer" end
]]

-- ============================================================================
-- GLOBAL ID COUNTER
-- ============================================================================
_pz_next_id = 100000

function _pz_gen_id()
    _pz_next_id = _pz_next_id + 1
    return _pz_next_id
end

-- ============================================================================
-- PZ GLOBAL FUNCTIONS
-- ============================================================================
function getDebug() return true end
function getText(key) return key or "" end
function isServer() return false end
function isClient() return true end
function isCoopHost() return false end
function getTimestampMs() return 0 end
function getActivatedMods()
    return { size = function(self) return 0 end, get = function(self, i) return "" end }
end

function ZombRand(a, b)
    if b then return math.floor((a + b) / 2)
    else return 0 end
end

function instanceof(obj, className)
    if obj == nil then return false end
    if type(obj) == "table" and obj._type then
        return obj._type == className
    end
    return false
end

function sendServerCommand(...) end
function sendClientCommand(...) end
function syncItemModData(...) end
function syncHandWeaponFields(...) end
function syncItemFields(...) end
-- triggerEvent(name, ...) — fire every listener registered on Events[name].
-- Matches real PZ's dispatch semantics so tests that verify whether a shim
-- or handler actually invokes listeners (not just fires a side-effect) can
-- observe the propagation directly. Also records a fire in event coverage.
function triggerEvent(name, ...)
    if type(name) ~= "string" or not Events then return end
    local evt = Events[name]
    if not evt or not evt._listeners then return end
    _pz_event_coverage[name] = _pz_event_coverage[name] or { registered = 0, fired = 0 }
    _pz_event_coverage[name].fired = _pz_event_coverage[name].fired + 1
    for _, fn in ipairs(evt._listeners) do
        pcall(fn, ...)
    end
end
function getFileWriter(...)
    return { write = function(self, line) end, close = function(self) end }
end

-- Lua 5.1 compat
if not math.pow then
    math.pow = function(base, exp) return base ^ exp end
end

-- PZ built-in
if not table.wipe then
    table.wipe = function(t) for k in pairs(t) do t[k] = nil end end
end

if not os then os = {} end
if not os.date then os.date = function(fmt) return "2026-01-01 12:00:00" end end

-- ============================================================================
-- EVENTS SYSTEM
-- ============================================================================
-- Event coverage telemetry: we track which events have listeners registered
-- and how many times each one fired (via triggerEvent or Sim dispatch). At
-- end of run the kit reports "registered but never fired" events so modders
-- can see which handlers aren't exercised by their tests.
_pz_event_coverage = _pz_event_coverage or {}

Events = {}
setmetatable(Events, { __index = function(self, key)
    local evt = {
        _listeners = {},
        _fireCount = 0,
        _name      = key,
    }
    evt.Add = function(fn)
        table.insert(evt._listeners, fn)
        _pz_event_coverage[key] = _pz_event_coverage[key] or { registered = 0, fired = 0 }
        _pz_event_coverage[key].registered = _pz_event_coverage[key].registered + 1
    end
    evt.Remove = function(fn)
        for i = #evt._listeners, 1, -1 do
            if evt._listeners[i] == fn then table.remove(evt._listeners, i) end
        end
    end
    rawset(self, key, evt)
    return evt
end })

-- ============================================================================
-- SANDBOX VARS (override per-mod as needed)
-- ============================================================================
SandboxVars = SandboxVars or {}

-- ============================================================================
-- GAMETIME MOCK
-- ============================================================================
_pz_world_hours = 100.0
_pz_hour_of_day = 14

GameTime = {}
GameTime._instance = {
    getWorldAgeHours = function(self) return _pz_world_hours end,
    getHour = function(self) return _pz_hour_of_day end,
}
function GameTime.getInstance() return GameTime._instance end

-- ============================================================================
-- TIMED ACTION QUEUE (stub)
-- ============================================================================
ISTimedActionQueue = { getTimedActionQueue = function(player) return nil end }

-- ============================================================================
-- ISBASETIMEDACTION (stub for mods that define timed actions)
-- ============================================================================
ISBaseTimedAction = ISBaseTimedAction or {}
ISBaseTimedAction.Type = "ISBaseTimedAction"
function ISBaseTimedAction:new() return setmetatable({}, { __index = self }) end
function ISBaseTimedAction:isValid() return true end
function ISBaseTimedAction:start() end
function ISBaseTimedAction:update() end
function ISBaseTimedAction:stop() end
function ISBaseTimedAction:perform() end
function ISBaseTimedAction:getDuration() return 100 end
function ISBaseTimedAction:setActionAnim() end
function ISBaseTimedAction:setAnimVariable() end
function ISBaseTimedAction:getJobDelta() return 0 end
-- Standard PZ pattern: ISBaseTimedAction:derive("ChildName") creates a
-- subclass with the given Type. Mods define timed actions with
-- `MyAction = ISBaseTimedAction:derive("MyAction")`.
function ISBaseTimedAction:derive(name)
    local child = setmetatable({}, { __index = self })
    child.Type = name
    return child
end

-- ============================================================================
-- ISTRANSFERACTION (mock for mods that delegate to vanilla transferItem)
-- ============================================================================
-- Real PZ provides ISTransferAction at shared/TimedActions/ISTransferAction.lua.
-- It's the canonical helper for moving an item between containers, handling
-- unequip, worn-items removal, OnClothingUpdated dispatch, and the special
-- item swaps (radio, lit candle/lantern). Mods that delegate to it for
-- MP-safe moves need it present in the offline harness too.
--
-- This mock covers the observable surface: DoRemoveItem/Remove on source,
-- AddItem on destination, removeItemOnCharacter if the dest isn't the
-- character's own inventory. Full visual behaviour (animations, device
-- data preservation) isn't simulated.

ISTransferAction = ISTransferAction or {}

--- Remove an item from a character: attached items, then hand/worn slots.
--- Fires OnClothingUpdated via triggerEvent if equipped state changed,
--- matching vanilla's observable contract.
function ISTransferAction:removeItemOnCharacter(character, item)
    if not character or not item then return true end
    if character.removeAttachedItem then character:removeAttachedItem(item) end
    if character.isEquipped and character:isEquipped(item) then
        if character.removeFromHands then character:removeFromHands(item) end
        if character.removeWornItem then character:removeWornItem(item, false) end
        if triggerEvent then triggerEvent("OnClothingUpdated", character) end
    end
    return true
end

--- Move an item between containers. dropSquare is the floor square when
--- destContainer is the floor; nil otherwise. The mock doesn't implement
--- the radio / CandleLit / Lantern_HurricaneLit item-type swaps —
--- tests that need those should use real PZ.
function ISTransferAction:transferItem(character, item, srcContainer, destContainer, dropSquare)
    if srcContainer then
        if srcContainer.DoRemoveItem then
            srcContainer:DoRemoveItem(item)
        elseif srcContainer.Remove then
            srcContainer:Remove(item)
        end
        if sendRemoveItemFromContainer then
            sendRemoveItemFromContainer(srcContainer, item)
        end
    end

    if destContainer and destContainer.AddItem then
        destContainer:AddItem(item)
    end

    if character and destContainer and character.getInventory
        and character:getInventory() ~= destContainer
    then
        self:removeItemOnCharacter(character, item)
    end

    return item
end

-- ============================================================================
-- WORLD / CELL / GRIDSQUARE MOCKS
-- ============================================================================
_pz_rain_intensity = 0.0
_pz_temperature = 20.0
_pz_is_outside = false

function _pz_create_mock_square(opts)
    opts = opts or {}
    local square = {
        _type = "IsoGridSquare",
        _isOutside = opts.isOutside or false,
        _room = opts.room,
        _x = opts.x or 0,
        _y = opts.y or 0,
        _z = opts.z or 0,
    }
    square.isOutside = function(self) return self._isOutside end
    square.getRoom = function(self)
        if self._room then
            return { getName = function() return self._room end }
        end
        if self._isOutside then return nil end
        return { getName = function() return "room" end }
    end
    square.getX = function(self) return self._x end
    square.getY = function(self) return self._y end
    square.getZ = function(self) return self._z end
    square.getMovingObjects = function(self)
        return { size = function() return 0 end, get = function(_, i) return nil end }
    end
    return square
end

_pz_climate_manager = {
    getRainIntensity = function(self) return _pz_rain_intensity end,
    getTemperature = function(self) return _pz_temperature end,
    getWindIntensity = function(self) return 0.0 end,
    getAirTemperatureForSquare = function(self, sq) return _pz_temperature end,
}

_pz_world = {
    _type = "IsoWorld",
    getClimateManager = function(self) return _pz_climate_manager end,
    getMetaGrid = function(self)
        return { getWidth = function() return 300 end, getHeight = function() return 300 end }
    end,
    getCell = function(self) return _pz_cell end,
}

_pz_cell = {
    _type = "IsoCell",
    getGridSquare = function(self, x, y, z) return _pz_create_mock_square({x=x, y=y, z=z}) end,
    getWorldX = function(self) return 0 end,
    getWorldY = function(self) return 0 end,
}

function getWorld() return _pz_world end
function getCell() return _pz_cell end

-- ============================================================================
-- CHARACTER STATS (body damage, moodles, skills)
-- ============================================================================
function _pz_create_mock_body_damage()
    local bd = {
        _overall = 0,
        _infected = false,
        _bitten = false,
        _scratched = false,
    }
    bd.getOverallBodyHealth = function(self) return self._overall end
    bd.IsInfected = function(self) return self._infected end
    bd.IsBitten = function(self) return self._bitten end
    bd.IsScratched = function(self) return self._scratched end
    bd.RestoreToFullHealth = function(self) self._overall = 0 end
    bd.getBodyPartHealth = function(self, part) return 100 end
    return bd
end

-- CharacterStat enum values (matches PZ's CharacterStat Java enum)
CharacterStat = {
    ENDURANCE = "ENDURANCE",
    FATIGUE = "FATIGUE",
    HUNGER = "HUNGER",
    THIRST = "THIRST",
    STRESS = "STRESS",
    BOREDOM = "BOREDOM",
    UNHAPPINESS = "UNHAPPINESS",
    PANIC = "PANIC",
    FITNESS = "FITNESS",
    STRENGTH = "STRENGTH",
}

function _pz_create_mock_stats()
    local stats = {
        _values = {
            ENDURANCE = 1.0,
            FATIGUE = 0.0,
            HUNGER = 0.0,
            THIRST = 0.0,
            STRESS = 0.0,
            BOREDOM = 0.0,
            UNHAPPINESS = 0.0,
            PANIC = 0.0,
            FITNESS = 5.0,
            STRENGTH = 5.0,
        },
    }
    -- Real PZ API: player:getStats():get(CharacterStat.ENDURANCE)
    stats.get = function(self, stat) return self._values[stat] or 0.0 end
    stats.set = function(self, stat, v) self._values[stat] = v end
    stats.remove = function(self, stat, amount)
        self._values[stat] = math.max(0, (self._values[stat] or 0) - amount)
    end
    stats.getEnduranceWarning = function(self) return 0.2 end
    return stats
end

function _pz_create_mock_xp()
    local xp = { _perks = {} }
    xp.getLevel = function(self, perk) return self._perks[perk] or 0 end
    xp.setLevel = function(self, perk, level) self._perks[perk] = level end
    xp.AddXP = function(self, perk, amount) end
    return xp
end

-- ============================================================================
-- ISOZOMBIE MOCK
-- ============================================================================
function _pz_create_mock_zombie(opts)
    opts = opts or {}
    local zombie = {
        _type = "IsoZombie",
        _health = opts.health or 1.8,
        _staggerBack = false,
        _onFire = false,
        _crawling = opts.crawling or false,
        _x = opts.x or 0,
        _y = opts.y or 0,
        _id = _pz_gen_id(),
    }
    zombie.getHealth = function(self) return self._health end
    zombie.setHealth = function(self, v) self._health = v end
    zombie.isAlive = function(self) return self._health > 0 end
    zombie.isDead = function(self) return self._health <= 0 end
    zombie.setStaggerBack = function(self, v) self._staggerBack = v end
    zombie.isStaggerBack = function(self) return self._staggerBack end
    zombie.setStaggerTimeMod = function(self, v) self._staggerTimeMod = v end
    zombie.getStaggerTimeMod = function(self) return self._staggerTimeMod end
    zombie.SetOnFire = function(self) self._onFire = true end
    zombie.isOnFire = function(self) return self._onFire end
    zombie.setFireSpreadProbability = function(self, v) self._fireSpread = v end
    zombie.setFireKillRate = function(self, v) self._fireKillRate = v end
    zombie.isCrawling = function(self) return self._crawling end
    zombie.getX = function(self) return self._x end
    zombie.getY = function(self) return self._y end
    zombie.getOnlineID = function(self) return self._id end
    zombie.getID = function(self) return self._id end
    zombie.getCurrentSquare = function(self)
        return _pz_create_mock_square({x=self._x, y=self._y})
    end
    return zombie
end

-- ============================================================================
-- MOCK PLAYER
-- ============================================================================
_pz_player_moddata = {}
_pz_player_inventory = {
    _items = {},
    AddItem = function(self, item) table.insert(self._items, item); return item end,
    removeAllItems = function(self) self._items = {} end,
    containsTypeRecurse = function(self, fullType)
        for _, item in ipairs(self._items) do
            if item and item.getFullType and item:getFullType() == fullType then return true end
        end
        return false
    end,
    getItems = function(self)
        return { size = function() return #self._items end, get = function(_, i) return self._items[i + 1] end }
    end,
    getItemById = function(self, id)
        for _, item in ipairs(self._items) do
            if item and item.getID then
                local itemId = item:getID()
                if itemId == id or tonumber(itemId) == tonumber(id) then
                    return item
                end
            end
        end
        return nil
    end,
}

_pz_player_body_damage = _pz_create_mock_body_damage()
_pz_player_stats = _pz_create_mock_stats()
_pz_player_xp = _pz_create_mock_xp()

_pz_player = {
    _type = "IsoPlayer",
    _primaryHand = nil,
    _secondaryHand = nil,
    _traits = {},
    _isOutside = false,
    _bloodLevel = 0,  -- 0.0-1.0 per body part

    getInventory = function(self) return _pz_player_inventory end,
    setPrimaryHandItem = function(self, item) self._primaryHand = item end,
    getPrimaryHandItem = function(self) return self._primaryHand end,
    setSecondaryHandItem = function(self, item) self._secondaryHand = item end,
    getSecondaryHandItem = function(self) return self._secondaryHand end,
    getPlayerNum = function(self) return 0 end,
    getModData = function(self) return _pz_player_moddata end,
    getUsername = function(self) return "TestPlayer" end,
    getDisplayName = function(self) return "TestPlayer" end,

    -- Body / Health
    getBodyDamage = function(self) return _pz_player_body_damage end,
    getStats = function(self) return _pz_player_stats end,
    getXp = function(self) return _pz_player_xp end,

    -- Traits (configurable per test)
    hasTrait = function(self, trait) return self._traits[trait] == true end,

    -- Position / World
    getCurrentSquare = function(self)
        return _pz_create_mock_square({ isOutside = self._isOutside })
    end,
    isOutside = function(self) return self._isOutside end,
    getX = function(self) return 5000 end,
    getY = function(self) return 5000 end,
    getZ = function(self) return 0 end,
    getVehicle = function(self) return nil end,
    getOnlineID = function(self) return 1 end,

    -- Visual state
    getHumanVisual = function(self)
        local bloodLevel = self._bloodLevel
        return {
            getBlood = function(_, part) return bloodLevel end,
            setBlood = function(_, part, v) end,
        }
    end,
    getClothingItem_Head = function(self) return nil end,
    isAsleep = function(self) return false end,
    IsRunning = function(self) return false end,  -- capital I matches PZ
    isSprinting = function(self) return false end,

    -- MP ModData broadcast. Inherited from IsoObject in real PZ; in-game this
    -- sends the ObjectModData packet and triggers a save flag. In tests we
    -- just no-op — the mock env has no network, no save pipeline. Mods that
    -- use transmitModData for client→server sync (vs sendClientCommand) need
    -- this to exist as a callable method, or the test harness crashes.
    transmitModData = function(self) end,
}

function getSpecificPlayer(index) return _pz_player end
function getPlayer() return _pz_player end

-- ============================================================================
-- MOCK WEAPON FACTORY
-- ============================================================================

-- Weapon scripts table — populate via weapon_scripts.lua or your own data
_pz_weapon_scripts = _pz_weapon_scripts or {}

function _pz_create_mock_script(scriptType, stats)
    return {
        getFullName = function(self) return scriptType end,
        getDisplayName = function(self) return stats._displayName or stats._name or "" end,
        getMaxDamage = function(self) return stats.maxDamage or 1.0 end,
        getMinDamage = function(self) return stats.minDamage or 0.5 end,
        getCriticalChance = function(self) return stats.criticalChance or 0 end,
    }
end

function _pz_create_mock_weapon(scriptType, statsTable)
    -- CLOSURE-BASED MOCK
    -- ===================
    -- Private state lives in `priv`, a local table captured by method closures.
    -- The returned `weapon` table exposes ONLY public methods. External writes
    -- to `weapon._anything` land as harmless new fields on the empty outer
    -- table and do NOT change the mock's behavior — matching real PZ where
    -- such writes either throw or have no effect on the underlying Java object.
    --
    -- To change behavior, override the method (works in both mock and real PZ):
    --     weapon.isContainsClip = function() return true end
    --
    -- Reading legacy `_foo` fields that other mods may have relied on is
    -- still supported through a read-only metatable __index — but those reads
    -- now fall through the closure, so they return the live value.

    local priv = {}
    for k, v in pairs(statsTable) do end  -- no direct copy; go through stats
    priv.stats = {}
    for k, v in pairs(statsTable) do priv.stats[k] = v end
    priv.modData = {}
    priv.id = _pz_gen_id()
    priv.scriptType = scriptType
    priv.isRanged = priv.stats._isRanged or false
    priv.name = priv.stats._name or "Mock Weapon"
    priv.displayName = priv.stats._displayName or priv.stats._name or "Mock Weapon"
    priv.currentName = priv.displayName
    priv.categories = priv.stats._categories or {}
    priv.parts = {}
    priv.hasHeadCondition = priv.stats._hasHeadCondition or false
    priv.headCondition = priv.stats._headConditionMax or -1
    priv.headConditionMax = priv.stats._headConditionMax or -1
    priv.hasSharpness = priv.stats._hasSharpness or false
    priv.sharpness = 1.0
    priv.maxSharpness = 1.0
    priv.condition = priv.stats.conditionMax or 10
    priv.timesRepaired = 0
    priv.currentAmmoCount = 0
    priv.magazineType = priv.stats._magazineType or ""
    priv.reloadType = priv.stats._reloadType or ""
    priv.containsClip = false
    priv.fireStartingChance = priv.stats.fireStartingChance or 0
    priv.fireStartingEnergy = priv.stats.fireStartingEnergy or 0
    priv.script = _pz_create_mock_script(scriptType, priv.stats)

    local weapon = {}

    weapon.getID = function(self) return priv.id end
    weapon.getScriptItem = function(self) return priv.script end
    weapon.getName = function(self) return priv.currentName end
    weapon.getDisplayName = function(self) return priv.currentName end
    weapon.setName = function(self, name) priv.currentName = name end
    weapon.getType = function(self) return priv.scriptType end
    weapon.getFullType = function(self) return priv.scriptType end
    weapon.IsWeapon = function(self) return true end
    weapon.isRanged = function(self) return priv.isRanged end
    weapon.getModData = function(self) return priv.modData end

    -- Sharpness
    weapon.hasSharpness = function(self) return priv.hasSharpness end
    weapon.getSharpness = function(self) return priv.sharpness end
    weapon.setSharpness = function(self, v) priv.sharpness = v end
    weapon.getMaxSharpness = function(self) return priv.maxSharpness end
    weapon.applyMaxSharpness = function(self) priv.sharpness = 1.0 end

    -- Head condition
    weapon.hasHeadCondition = function(self) return priv.hasHeadCondition end
    weapon.getHeadCondition = function(self) return self._headCondition end
    weapon.setHeadCondition = function(self, v) self._headCondition = v end
    weapon.getHeadConditionMax = function(self) return self._headConditionMax end

    -- Condition
    weapon.getCondition = function(self) return priv.condition end
    weapon.setCondition = function(self, v) priv.condition = math.min(v, priv.stats.conditionMax or 10) end
    weapon.getConditionMax = function(self) return priv.stats.conditionMax or 10 end
    weapon.setConditionMax = function(self, v)
        priv.stats.conditionMax = v
        if priv.condition > v then priv.condition = v end
    end
    weapon.getConditionLowerChance = function(self) return priv.stats.conditionLowerChance or 10 end
    weapon.setConditionLowerChance = function(self, v) priv.stats.conditionLowerChance = v end

    -- Damage (matches real PZ: sharpness only scales delta above minDamage)
    weapon.getMinDamage = function(self) return priv.stats.minDamage or 0.5 end
    weapon.setMinDamage = function(self, v) priv.stats.minDamage = v end
    weapon.getMaxDamage = function(self)
        local raw = priv.stats.maxDamage or 1.0
        if priv.hasSharpness and raw > (priv.stats.minDamage or 0.5) then
            local minDmg = priv.stats.minDamage or 0.5
            return minDmg + (raw - minDmg) * ((priv.sharpness + 1.0) / 2.0)
        end
        return raw
    end
    weapon.setMaxDamage = function(self, v) priv.stats.maxDamage = v end

    -- Critical (sharpness-affected)
    weapon.getCriticalChance = function(self)
        local raw = priv.stats.criticalChance or 0
        return priv.hasSharpness and (raw * priv.sharpness) or raw
    end
    weapon.setCriticalChance = function(self, v) priv.stats.criticalChance = v end
    weapon.getCriticalDamageMultiplier = function(self)
        local raw = priv.stats.critDmgMultiplier or 2.0
        return priv.hasSharpness and (raw * ((priv.sharpness + 1.0) / 2.0)) or raw
    end
    weapon.setCriticalDamageMultiplier = function(self, v) priv.stats.critDmgMultiplier = v end

    -- Range, Speed, Pushback, HitCount
    weapon.getMaxRange = function(self) return priv.stats.maxRange or 1.0 end
    weapon.setMaxRange = function(self, v) priv.stats.maxRange = v end
    weapon.getMinRange = function(self) return priv.stats.minRange or 0 end
    weapon.setMinRange = function(self, v) priv.stats.minRange = v end
    weapon.getBaseSpeed = function(self) return priv.stats.baseSpeed or 1.0 end
    weapon.setBaseSpeed = function(self, v) priv.stats.baseSpeed = v end
    weapon.getPushBackMod = function(self) return priv.stats.pushBackMod or 0 end
    weapon.setPushBackMod = function(self, v) priv.stats.pushBackMod = v end
    weapon.getMaxHitCount = function(self) return priv.stats.maxHitCount or 1 end
    weapon.setMaxHitCount = function(self, v) priv.stats.maxHitCount = v end

    -- Door/Tree damage (sharpness-affected, min 1)
    weapon.getDoorDamage = function(self)
        local raw = priv.stats.doorDamage or 0
        if priv.hasSharpness and raw > 0 then return math.max(1, math.floor(raw * ((priv.sharpness + 1.0) / 2.0))) end
        return raw
    end
    weapon.setDoorDamage = function(self, v) priv.stats.doorDamage = v end
    weapon.getTreeDamage = function(self)
        local raw = priv.stats.treeDamage or 0
        if priv.hasSharpness and raw > 0 then return math.max(1, math.floor(raw * ((priv.sharpness + 1.0) / 2.0))) end
        return raw
    end
    weapon.setTreeDamage = function(self, v) priv.stats.treeDamage = v end

    -- Endurance, Knockdown, Noise, Sound
    weapon.getEnduranceMod = function(self) return priv.stats.enduranceMod or 0.5 end
    weapon.setEnduranceMod = function(self, v) priv.stats.enduranceMod = v end
    weapon.getKnockdownMod = function(self) return priv.stats.knockdownMod or 0 end
    weapon.setKnockdownMod = function(self, v) priv.stats.knockdownMod = v end
    weapon.getNoiseRange = function(self) return priv.stats.noiseRange or 0 end
    weapon.setNoiseRange = function(self, v) priv.stats.noiseRange = v end
    weapon.getSoundRadius = function(self) return priv.stats.soundRadius or 0 end
    weapon.setSoundRadius = function(self, v) priv.stats.soundRadius = v end
    weapon.getSoundGain = function(self) return priv.stats.soundGain or 1.0 end
    weapon.setSoundGain = function(self, v) priv.stats.soundGain = v end

    -- Firearm stats
    weapon.getHitChance = function(self) return priv.stats.hitChance or 0 end
    weapon.setHitChance = function(self, v) priv.stats.hitChance = v end
    weapon.getRecoilDelay = function(self) return priv.stats.recoilDelay or 0 end
    weapon.setRecoilDelay = function(self, v) priv.stats.recoilDelay = v end
    weapon.getReloadTime = function(self) return priv.stats.reloadTime or 0 end
    weapon.setReloadTime = function(self, v) priv.stats.reloadTime = v end
    weapon.getAimingTime = function(self) return priv.stats.aimingTime or 0 end
    weapon.setAimingTime = function(self, v) priv.stats.aimingTime = v end
    weapon.getClipSize = function(self) return priv.stats.clipSize or 0 end
    weapon.setClipSize = function(self, v) priv.stats.clipSize = v end
    weapon.getMaxAmmo = function(self) return priv.stats.maxAmmo or 0 end
    weapon.setMaxAmmo = function(self, v) priv.stats.maxAmmo = v end
    weapon.getJamGunChance = function(self) return priv.stats.jamGunChance or 0 end
    weapon.setJamGunChance = function(self, v) priv.stats.jamGunChance = v end

    -- Fire starting
    weapon.getFireStartingChance = function(self) return priv.fireStartingChance end
    weapon.setFireStartingChance = function(self, v) priv.fireStartingChance = v end
    weapon.getFireStartingEnergy = function(self) return priv.fireStartingEnergy end
    weapon.setFireStartingEnergy = function(self, v) priv.fireStartingEnergy = v end

    -- Weight (read-only in B42)
    weapon.getActualWeight = function(self) return 2.0 end
    weapon.setActualWeight = function(self, v) end

    -- Magazine — getters go through closure, so `weapon._magazineType = ""`
    -- (a write to the outer table) does NOT change what getMagazineType returns.
    -- Tests must override the method: `weapon.getMagazineType = function() return "" end`.
    weapon.getMagazineType = function(self) return priv.magazineType end
    weapon.setMagazineType = function(self, v) priv.magazineType = v end
    weapon.getWeaponReloadType = function(self) return priv.reloadType end
    weapon.isContainsClip = function(self) return priv.containsClip end
    weapon.getCurrentAmmoCount = function(self) return priv.currentAmmoCount end
    weapon.setCurrentAmmoCount = function(self, v) priv.currentAmmoCount = v end
    weapon.getTimesRepaired = function(self) return priv.timesRepaired end

    -- Weapon parts (stub)
    weapon.getWeaponPart = function(self, partType) return nil end
    weapon.getAllWeaponParts = function(self)
        return { size = function() return 0 end, get = function(self, i) return nil end }
    end

    -- Compatibility: `_type` needs to be readable for instanceof(). Set it on
    -- the weapon table directly so `weapon._type` reads return "HandWeapon".
    -- External writes to `weapon._type = "X"` succeed (overwriting), matching
    -- real PZ where such writes are generally tolerated for existing keys.
    weapon._type = "HandWeapon"

    return weapon
end

-- ============================================================================
-- STRICT MOCK MODE (opt-in via config: strict_mocks = true)
-- ============================================================================
-- Real PZ HandWeapon/InventoryItem are Java objects. Their Lua proxy rejects
-- arbitrary private-field writes: e.g. `weapon._containsClip = true` throws
-- because HandWeapon has no such Java field. Our mock is a plain Lua table
-- so those writes silently succeed, masking test bugs.
--
-- Strict mode installs a __newindex metatable that rejects writes to keys
-- not already on the object. Since all private `_fields` are set during
-- construction, internal setters that write `self._foo = v` bypass
-- __newindex (Lua 5.1 only calls __newindex for absent keys). External
-- writes to new `_foo` names trigger the guard.
--
-- To change behavior, override the METHOD (works in both mock and real PZ):
--     weapon.isContainsClip  = function() return true end
--     weapon.getMagazineType = function() return "" end
if _pz_strict_mocks == nil then _pz_strict_mocks = false end

--- Wraps a mock object in a facade whose __newindex enforces real-PZ-style
--- private-field immutability. Internal setters (which write to existing
--- private fields set during construction) pass through unchanged; external
--- writes to NEW `_foo` field names on the facade are rejected — matching
--- the Exception that real PZ throws for the same pattern.
function _pz_seal_mock(obj, typeLabel)
    if not _pz_strict_mocks then return obj end
    local facade = {}
    setmetatable(facade, {
        __index = function(_, k) return obj[k] end,
        __newindex = function(_, k, v)
            -- Existing key (either a pre-constructed field or a previously-set
            -- override) — allow the write through to the real object.
            if rawget(obj, k) ~= nil then
                obj[k] = v
                return
            end
            -- New private field — reject. This is the pattern real PZ throws
            -- on: weapon._containsClip = true when `_containsClip` was never
            -- declared on the Java class.
            if type(k) == "string" and k:sub(1, 1) == "_" then
                error(string.format(
                    "Cannot set private field '%s' on mock %s — real PZ " ..
                    "rejects unknown field writes on Java objects. Override " ..
                    "the method instead: " ..
                    "`obj.<methodName> = function(self) return <value> end`",
                    k, typeLabel), 2)
            end
            -- New public field (e.g. method override) — allow.
            obj[k] = v
        end,
    })
    return facade
end

-- Mock non-weapon items (magazines, clips, etc.)
_pz_item_scripts = _pz_item_scripts or {}

function _pz_create_mock_item(fullType, stats)
    _pz_next_id = _pz_next_id + 1
    local item = {
        _type = "InventoryItem",
        _fullType = fullType,
        _id = _pz_next_id,
        _modData = {},
        _stats = stats or {},
    }
    item.getFullType = function(self) return self._fullType end
    item.getID = function(self) return self._id end
    item.getModData = function(self) return self._modData end
    item.getMaxAmmo = function(self) return self._stats.maxAmmo or 0 end
    item.setMaxAmmo = function(self, v) self._stats.maxAmmo = v end
    item.getClipSize = function(self) return self._stats.clipSize or 0 end
    item.setClipSize = function(self, v) self._stats.clipSize = v end
    item.getName = function(self) return self._stats._name or fullType end
    item.getDisplayName = function(self) return self._stats._displayName or self._stats._name or fullType end
    item.getScriptItem = function(self)
        return {
            getFullName = function() return fullType end,
            getDisplayName = function() return self._stats._displayName or self._stats._name or fullType end,
            getMaxAmmo = function() return self._stats.maxAmmo or 0 end,
        }
    end
    item.setName = function(self, name) self._stats._name = name end
    return _pz_seal_mock(item, "InventoryItem")
end

-- instanceItem: checks weapons first, then generic items
function instanceItem(fullType)
    local stats = _pz_weapon_scripts[fullType]
    if stats then return _pz_create_mock_weapon(fullType, stats) end
    local itemStats = _pz_item_scripts[fullType]
    if itemStats then return _pz_create_mock_item(fullType, itemStats) end
    return nil
end

print("[PZTestKit] Mock environment loaded")
