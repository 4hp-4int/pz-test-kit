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
function triggerEvent(...) end
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
Events = {}
setmetatable(Events, { __index = function(self, key)
    local evt = { _listeners = {} }
    evt.Add = function(fn) table.insert(evt._listeners, fn) end
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
}

_pz_player = {
    _type = "IsoPlayer",
    _primaryHand = nil,
    _secondaryHand = nil,
    getInventory = function(self) return _pz_player_inventory end,
    setPrimaryHandItem = function(self, item) self._primaryHand = item end,
    getPrimaryHandItem = function(self) return self._primaryHand end,
    setSecondaryHandItem = function(self, item) self._secondaryHand = item end,
    getSecondaryHandItem = function(self) return self._secondaryHand end,
    getPlayerNum = function(self) return 0 end,
    getBodyDamage = function(self) return { RestoreToFullHealth = function(self) end } end,
    getModData = function(self) return _pz_player_moddata end,
    hasTrait = function(self, trait) return false end,
    getUsername = function(self) return "TestPlayer" end,
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
    local stats = {}
    for k, v in pairs(statsTable) do stats[k] = v end

    local weapon = {
        _type = "HandWeapon",
        _stats = stats,
        _modData = {},
        _id = _pz_gen_id(),
        _scriptType = scriptType,
        _isRanged = stats._isRanged or false,
        _name = stats._name or "Mock Weapon",
        _displayName = stats._displayName or stats._name or "Mock Weapon",
        _currentName = stats._displayName or stats._name or "Mock Weapon",
        _categories = stats._categories or {},
        _parts = {},
        _hasHeadCondition = stats._hasHeadCondition or false,
        _headCondition = stats._headConditionMax or -1,
        _headConditionMax = stats._headConditionMax or -1,
        _hasSharpness = stats._hasSharpness or false,
        _sharpness = 1.0,
        _maxSharpness = 1.0,
        _condition = stats.conditionMax or 10,
        _timesRepaired = 0,
        _currentAmmoCount = 0,
        _magazineType = stats._magazineType or "",
        _reloadType = stats._reloadType or "",
        _containsClip = false,
        _fireStartingChance = stats.fireStartingChance or 0,
        _fireStartingEnergy = stats.fireStartingEnergy or 0,
    }

    local scriptObj = _pz_create_mock_script(scriptType, stats)
    weapon._script = scriptObj

    weapon.getID = function(self) return self._id end
    weapon.getScriptItem = function(self) return self._script end
    weapon.getName = function(self) return self._currentName end
    weapon.getDisplayName = function(self) return self._currentName end
    weapon.setName = function(self, name) self._currentName = name end
    weapon.getType = function(self) return self._scriptType end
    weapon.getFullType = function(self) return self._scriptType end
    weapon.IsWeapon = function(self) return true end
    weapon.isRanged = function(self) return self._isRanged end
    weapon.getModData = function(self) return self._modData end

    -- Sharpness
    weapon.hasSharpness = function(self) return self._hasSharpness end
    weapon.getSharpness = function(self) return self._sharpness end
    weapon.setSharpness = function(self, v) self._sharpness = v end
    weapon.getMaxSharpness = function(self) return self._maxSharpness end
    weapon.applyMaxSharpness = function(self) self._sharpness = 1.0 end

    -- Head condition
    weapon.hasHeadCondition = function(self) return self._hasHeadCondition end
    weapon.getHeadCondition = function(self) return self._headCondition end
    weapon.setHeadCondition = function(self, v) self._headCondition = v end
    weapon.getHeadConditionMax = function(self) return self._headConditionMax end

    -- Condition
    weapon.getCondition = function(self) return self._condition end
    weapon.setCondition = function(self, v) self._condition = math.min(v, self._stats.conditionMax or 10) end
    weapon.getConditionMax = function(self) return self._stats.conditionMax or 10 end
    weapon.setConditionMax = function(self, v) self._stats.conditionMax = v; if self._condition > v then self._condition = v end end
    weapon.getConditionLowerChance = function(self) return self._stats.conditionLowerChance or 10 end
    weapon.setConditionLowerChance = function(self, v) self._stats.conditionLowerChance = v end

    -- Damage (matches real PZ Java: sharpness only affects delta above minDamage)
    weapon.getMinDamage = function(self) return self._stats.minDamage or 0.5 end
    weapon.setMinDamage = function(self, v) self._stats.minDamage = v end
    weapon.getMaxDamage = function(self)
        local raw = self._stats.maxDamage or 1.0
        if self._hasSharpness and raw > self:getMinDamage() then
            local minDmg = self:getMinDamage()
            return minDmg + (raw - minDmg) * ((self._sharpness + 1.0) / 2.0)
        end
        return raw
    end
    weapon.setMaxDamage = function(self, v) self._stats.maxDamage = v end

    -- Critical (sharpness-affected)
    weapon.getCriticalChance = function(self)
        local raw = self._stats.criticalChance or 0
        return self._hasSharpness and (raw * self._sharpness) or raw
    end
    weapon.setCriticalChance = function(self, v) self._stats.criticalChance = v end
    weapon.getCriticalDamageMultiplier = function(self)
        local raw = self._stats.critDmgMultiplier or 2.0
        return self._hasSharpness and (raw * ((self._sharpness + 1.0) / 2.0)) or raw
    end
    weapon.setCriticalDamageMultiplier = function(self, v) self._stats.critDmgMultiplier = v end

    -- Range, Speed, Pushback, HitCount
    weapon.getMaxRange = function(self) return self._stats.maxRange or 1.0 end
    weapon.setMaxRange = function(self, v) self._stats.maxRange = v end
    weapon.getMinRange = function(self) return self._stats.minRange or 0 end
    weapon.setMinRange = function(self, v) self._stats.minRange = v end
    weapon.getBaseSpeed = function(self) return self._stats.baseSpeed or 1.0 end
    weapon.setBaseSpeed = function(self, v) self._stats.baseSpeed = v end
    weapon.getPushBackMod = function(self) return self._stats.pushBackMod or 0 end
    weapon.setPushBackMod = function(self, v) self._stats.pushBackMod = v end
    weapon.getMaxHitCount = function(self) return self._stats.maxHitCount or 1 end
    weapon.setMaxHitCount = function(self, v) self._stats.maxHitCount = v end

    -- Door/Tree damage (sharpness-affected, min 1)
    weapon.getDoorDamage = function(self)
        local raw = self._stats.doorDamage or 0
        if self._hasSharpness and raw > 0 then return math.max(1, math.floor(raw * ((self._sharpness + 1.0) / 2.0))) end
        return raw
    end
    weapon.setDoorDamage = function(self, v) self._stats.doorDamage = v end
    weapon.getTreeDamage = function(self)
        local raw = self._stats.treeDamage or 0
        if self._hasSharpness and raw > 0 then return math.max(1, math.floor(raw * ((self._sharpness + 1.0) / 2.0))) end
        return raw
    end
    weapon.setTreeDamage = function(self, v) self._stats.treeDamage = v end

    -- Endurance, Knockdown, Noise, Sound
    weapon.getEnduranceMod = function(self) return self._stats.enduranceMod or 0.5 end
    weapon.setEnduranceMod = function(self, v) self._stats.enduranceMod = v end
    weapon.getKnockdownMod = function(self) return self._stats.knockdownMod or 0 end
    weapon.setKnockdownMod = function(self, v) self._stats.knockdownMod = v end
    weapon.getNoiseRange = function(self) return self._stats.noiseRange or 0 end
    weapon.setNoiseRange = function(self, v) self._stats.noiseRange = v end
    weapon.getSoundRadius = function(self) return self._stats.soundRadius or 0 end
    weapon.setSoundRadius = function(self, v) self._stats.soundRadius = v end
    weapon.getSoundGain = function(self) return self._stats.soundGain or 1.0 end
    weapon.setSoundGain = function(self, v) self._stats.soundGain = v end

    -- Firearm stats
    weapon.getHitChance = function(self) return self._stats.hitChance or 0 end
    weapon.setHitChance = function(self, v) self._stats.hitChance = v end
    weapon.getRecoilDelay = function(self) return self._stats.recoilDelay or 0 end
    weapon.setRecoilDelay = function(self, v) self._stats.recoilDelay = v end
    weapon.getReloadTime = function(self) return self._stats.reloadTime or 0 end
    weapon.setReloadTime = function(self, v) self._stats.reloadTime = v end
    weapon.getAimingTime = function(self) return self._stats.aimingTime or 0 end
    weapon.setAimingTime = function(self, v) self._stats.aimingTime = v end
    weapon.getClipSize = function(self) return self._stats.clipSize or 0 end
    weapon.setClipSize = function(self, v) self._stats.clipSize = v end
    weapon.getMaxAmmo = function(self) return self._stats.maxAmmo or 0 end
    weapon.setMaxAmmo = function(self, v) self._stats.maxAmmo = v end
    weapon.getJamGunChance = function(self) return self._stats.jamGunChance or 0 end
    weapon.setJamGunChance = function(self, v) self._stats.jamGunChance = v end

    -- Fire starting
    weapon.getFireStartingChance = function(self) return self._fireStartingChance end
    weapon.setFireStartingChance = function(self, v) self._fireStartingChance = v end
    weapon.getFireStartingEnergy = function(self) return self._fireStartingEnergy end
    weapon.setFireStartingEnergy = function(self, v) self._fireStartingEnergy = v end

    -- Weight (read-only in B42)
    weapon.getActualWeight = function(self) return 2.0 end
    weapon.setActualWeight = function(self, v) end

    -- Magazine
    weapon.getMagazineType = function(self) return self._magazineType end
    weapon.setMagazineType = function(self, v) self._magazineType = v end
    weapon.getWeaponReloadType = function(self) return self._reloadType end
    weapon.isContainsClip = function(self) return self._containsClip end
    weapon.getCurrentAmmoCount = function(self) return self._currentAmmoCount end
    weapon.setCurrentAmmoCount = function(self, v) self._currentAmmoCount = v end
    weapon.getTimesRepaired = function(self) return self._timesRepaired end

    -- Weapon parts (stub)
    weapon.getWeaponPart = function(self, partType) return nil end
    weapon.getAllWeaponParts = function(self)
        return { size = function() return 0 end, get = function(self, i) return nil end }
    end

    return weapon
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
    return item
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
