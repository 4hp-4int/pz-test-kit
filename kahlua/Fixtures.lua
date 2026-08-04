--[[
    PZ Test Kit — Fixtures
    ======================
    Pure Lua-table factories for PZ game objects. Method names and return
    types are taken from PZ's decompiled Java source so tests can use them
    interchangeably with real PZ objects in-game.

    Usage:
        local w = PZTestKit.Fixtures.weapon({ maxDamage = 2.0 })
        local z = PZTestKit.Fixtures.zombie({ health = 1.5 })

    The factories live on `PZTestKit.Fixtures` but are also re-exported to
    the global helpers that mock_environment.lua already provides
    (`_pz_create_mock_weapon`, `_pz_create_mock_zombie`) for backwards
    compatibility with tests that call the lower-level API.
]]

PZTestKit = PZTestKit or {}
PZTestKit.Fixtures = PZTestKit.Fixtures or {}

local Fixtures = PZTestKit.Fixtures

--- Weapon fixture — Lua-table mock matching HandWeapon's public method
--- surface. Private state is held in a closure so external writes to
--- `weapon._privateField = x` do NOT change behavior (matching real PZ's
--- Java-object restrictions). To change state a test should call a setter
--- or pass a field via opts at construction time.
---
--- Verified against zombie/inventory/types/HandWeapon.java method names.
---
---@param opts table|nil Overrides: id, isRanged, name, maxDamage, minDamage,
---                      conditionMax, clipSize, maxAmmo, magazineType,
---                      containsClip, sharpness, hasSharpness
---@return table mock HandWeapon
function Fixtures.weapon(opts)
    opts = opts or {}
    local priv = {
        id            = opts.id          or (ZombRand and ZombRand(100000, 999999) or 123456),
        isRanged      = opts.isRanged    or false,
        name          = opts.name        or "MockWeapon",
        maxDamage     = opts.maxDamage   or 1.0,
        minDamage     = opts.minDamage   or 0.5,
        conditionMax  = opts.conditionMax or 10,
        condition     = opts.condition   or (opts.conditionMax or 10),
        clipSize      = opts.clipSize    or 0,
        maxAmmo       = opts.maxAmmo     or 0,
        magazineType  = opts.magazineType or "",
        containsClip  = opts.containsClip or false,
        sharpness     = opts.sharpness   or 1.0,
        hasSharpness  = opts.hasSharpness or false,
        modData       = {},
    }
    local w = { _type = "HandWeapon" }

    -- Identity / type
    w.getID           = function(self) return priv.id end
    w.getName         = function(self) return priv.name end
    w.getDisplayName  = function(self) return priv.name end
    w.getFullType     = function(self) return priv.name end
    w.getType         = function(self) return priv.name end
    w.IsWeapon        = function(self) return true end
    w.isRanged        = function(self) return priv.isRanged end
    w.getModData      = function(self) return priv.modData end

    -- Damage (sharpness-scaled delta for getMaxDamage matches HandWeapon.java)
    w.getMinDamage    = function(self) return priv.minDamage end
    w.setMinDamage    = function(self, v) priv.minDamage = v end
    w.getMaxDamage    = function(self)
        local raw = priv.maxDamage
        if priv.hasSharpness and raw > priv.minDamage then
            return priv.minDamage + (raw - priv.minDamage) * ((priv.sharpness + 1.0) / 2.0)
        end
        return raw
    end
    w.setMaxDamage    = function(self, v) priv.maxDamage = v end

    -- Condition
    w.getCondition    = function(self) return priv.condition end
    w.setCondition    = function(self, v) priv.condition = math.min(v, priv.conditionMax) end
    w.getConditionMax = function(self) return priv.conditionMax end
    w.setConditionMax = function(self, v)
        priv.conditionMax = v
        if priv.condition > v then priv.condition = v end
    end

    -- Sharpness
    w.hasSharpness    = function(self) return priv.hasSharpness end
    w.getSharpness    = function(self) return priv.sharpness end
    w.setSharpness    = function(self, v) priv.sharpness = v end

    -- Firearm / ammo (SyncHandWeaponFieldsPacket.java surface)
    w.getClipSize     = function(self) return priv.clipSize end
    w.setClipSize     = function(self, v) priv.clipSize = v end
    w.getMaxAmmo      = function(self) return priv.maxAmmo end
    w.setMaxAmmo      = function(self, v) priv.maxAmmo = v end
    w.getMagazineType = function(self) return priv.magazineType end
    w.setMagazineType = function(self, v) priv.magazineType = v end
    w.isContainsClip  = function(self) return priv.containsClip end

    -- Fire-on-hit fields (read by combat listeners that manually check traps)
    w.getFireStartingChance = function(self) return priv.fireStartingChance or 0 end
    w.setFireStartingChance = function(self, v) priv.fireStartingChance = v end
    w.getFireStartingEnergy = function(self) return priv.fireStartingEnergy or 0 end
    w.setFireStartingEnergy = function(self, v) priv.fireStartingEnergy = v end

    -- Script item surface for WeaponData.isValidWeapon validation
    w.getScriptItem   = function(self)
        return {
            getFullName    = function() return priv.name end,
            getDisplayName = function() return priv.name end,
            getMaxDamage   = function() return priv.maxDamage end,
            getMinDamage   = function() return priv.minDamage end,
        }
    end

    return w
end

--- Firearm preset — defaults to pistol-like stats. Pure convenience wrapper
--- over Fixtures.weapon({ isRanged = true, ... }).
function Fixtures.firearm(opts)
    opts = opts or {}
    local defaults = {
        isRanged     = true,
        name         = "MockPistol",
        magazineType = "Base.9mmClip",
        clipSize     = 15,
        maxAmmo      = 15,
        maxDamage    = 0.7,
        minDamage    = 0.3,
        conditionMax = 10,
    }
    for k, v in pairs(opts) do defaults[k] = v end
    return Fixtures.weapon(defaults)
end

--- Zombie fixture — matches real IsoZombie's Lua-exposed method surface.
--- Verified against IsoZombie.java / IsoGameCharacter.java / IsoMovingObject.java:
---   getHealth()        → float  (IsoGameCharacter)
---   setHealth(float)            (IsoGameCharacter)
---   isAlive()          → bool   (IsoGameCharacter)
---   isOnFire()         → bool   (IsoGameCharacter)
---   SetOnFire()                 (IsoGameCharacter — note capital S)
---   isCrawling()       → bool   (IsoZombie)
---   isStaggerBack()    → bool   (IsoZombie)
---   setStaggerBack(bool)        (IsoZombie)
---   getOnlineID()      → short  (IsoZombie)
---   getLastHitPart()   → String (IsoZombie)
---   getX/Y/Z()         → float  (IsoMovingObject)
---
---@param opts table|nil Overrides: health, crawling, onFire, id, x, y
---@return table mock IsoZombie
function Fixtures.zombie(opts)
    opts = opts or {}
    local priv = {
        health       = opts.health    or 1.8,
        alive        = opts.health == nil or opts.health > 0,
        onFire       = opts.onFire    or false,
        crawling     = opts.crawling  or false,
        staggerBack  = opts.staggerBack or false,
        id           = opts.id        or (ZombRand and ZombRand(1, 30000) or 42),
        x            = opts.x         or 0.0,
        y            = opts.y         or 0.0,
        z            = opts.z         or 0.0,
        lastHitPart  = opts.lastHitPart or nil,
        attachedItems = {},
    }
    local z = { _type = "IsoZombie" }

    z.getHealth         = function(self) return priv.health end
    z.setHealth         = function(self, v)
        priv.health = v
        priv.alive  = v > 0
    end
    z.isAlive           = function(self) return priv.alive end
    z.isDead            = function(self) return not priv.alive end
    z.isOnFire          = function(self) return priv.onFire end
    z.SetOnFire         = function(self) priv.onFire = true end
    z.setFireSpreadProbability = function(self, v) priv.fireSpread = v end
    z.setFireKillRate   = function(self, v) priv.fireKillRate = v end
    z.isCrawling        = function(self) return priv.crawling end
    z.isStaggerBack     = function(self) return priv.staggerBack end
    z.setStaggerBack    = function(self, v) priv.staggerBack = v end
    z.setStaggerTimeMod = function(self, v) priv.staggerTimeMod = v end
    z.getStaggerTimeMod = function(self) return priv.staggerTimeMod end
    z.getID             = function(self) return priv.id end
    z.getOnlineID       = function(self) return priv.id end
    z.getLastHitPart    = function(self) return priv.lastHitPart end
    z.getX              = function(self) return priv.x end
    z.getY              = function(self) return priv.y end
    z.getZ              = function(self) return priv.z end
    z.getAttachedItem   = function(self, loc) return priv.attachedItems[loc] end
    z.setAttachedItem   = function(self, loc, item) priv.attachedItems[loc] = item end

    return z
end

-- Re-export to the existing globals the mock_environment already uses so
-- test code that calls `_pz_create_mock_zombie` keeps working.
_pz_create_mock_weapon_fixture  = Fixtures.weapon
_pz_create_mock_firearm_fixture = Fixtures.firearm
_pz_create_mock_zombie_fixture  = Fixtures.zombie

-- ============================================================================
-- WORLD / INVENTORY FIXTURES
-- ============================================================================
-- Below this line are the fixtures that ship with 1.1 of the test kit:
-- square, worldItem, item, container, player, world, networkSpy, eventSpy.
-- They're built to be FAITHFUL to the real PZ Java surface they stand in for,
-- not just convenient stubs. Each method signature was cross-referenced
-- against decompiled B42 source (zombie.inventory.*, zombie.iso.*,
-- zombie.characters.*) before landing here.
--
-- Rule of construction for every method:
--   1. If PZ Java has the method, our mock has it too.
--   2. If PZ Java's impl has an observable side effect (mutates fields,
--      fires events, triggers broadcasts), the mock mirrors that side
--      effect — so tests catch regressions in mod code that relied on it.
--   3. Mocks never silently "succeed" operations that real PZ would reject.
--      AddItem with a duplicate id logs + returns the existing item (matches
--      ItemContainer.java:453-455). removeFromSquare on an object not in
--      the square is a no-op (matches IsoGridSquare.java:6268-6312).
--
-- INVARIANT: every mutating method increments a `_*Count` field and/or
-- records arguments, so a single-line Assert can prove "this happened
-- exactly N times" — the core duplication-regression test pattern.

--- Lua-table mock matching Java ArrayList's Lua-visible surface
--- (size() / get(i)). 0-indexed to match real Java iteration. Used
--- internally by container / square fixtures.
local function makeJavaList(backing)
    local list = { _items = backing or {} }
    list.size     = function(self) return #self._items end
    list.isEmpty  = function(self) return #self._items == 0 end
    list.get      = function(self, i) return self._items[i + 1] end
    list.add      = function(self, v) table.insert(self._items, v); return v end
    list.contains = function(self, v)
        for _, it in ipairs(self._items) do if it == v then return true end end
        return false
    end
    list.remove   = function(self, v)
        for i, it in ipairs(self._items) do
            if it == v then table.remove(self._items, i); return true end
        end
        return false
    end
    list.isEmpty  = function(self) return #self._items == 0 end
    return list
end

--- InventoryItem fixture. Verified against zombie/inventory/InventoryItem.java:
---   getID()/getFullType()/getName()/getType()/getActualWeight()/
---   getUnequippedWeight()/getContainer()/getWorldItem()/setWorldItem()/
---   getModData()/IsWeapon()/getCondition()/setCondition()/getConditionMax()/
---   isFavorite()/setFavorite()/setJobDelta()/setJobType()/getCurrentUsesFloat()
---
---@param opts table|nil Overrides: id, fullType, weight, condition,
---                      conditionMax, modData, favorite, uses, isWeapon
function Fixtures.item(opts)
    opts = opts or {}
    local priv = {
        id           = opts.id           or (ZombRand and ZombRand(100000, 999999) or 12345),
        fullType     = opts.fullType     or "Base.RippedSheets",
        weight       = opts.weight       or 0.1,
        condition    = opts.condition    or 100,
        conditionMax = opts.conditionMax or 100,
        modData      = opts.modData      or {},
        favorite     = opts.favorite     or false,
        uses         = opts.uses         or 1.0,
        isWeapon     = opts.isWeapon     or false,
        worldItem    = nil,
        container    = nil,
        jobDelta     = 0,
        jobType      = nil,
        -- Counters tests assert against.
        setWorldItemCount = 0,
        setJobDeltaCount  = 0,
    }
    local it = { _type = "InventoryItem" }
    it.getID              = function(self) return priv.id end
    it.getFullType        = function(self) return priv.fullType end
    it.getName            = function(self) return priv.fullType end
    it.getDisplayName     = function(self) return priv.fullType end
    it.getType            = function(self)
        return (priv.fullType or ""):match("%.(.+)$") or priv.fullType
    end
    it.getActualWeight     = function(self) return priv.weight end
    it.getUnequippedWeight = function(self) return priv.weight end
    it.getWeight           = function(self) return priv.weight end
    it.setActualWeight     = function(self, v) priv.weight = v end
    it.getCondition        = function(self) return priv.condition end
    it.setCondition        = function(self, v) priv.condition = math.min(v, priv.conditionMax) end
    it.getConditionMax     = function(self) return priv.conditionMax end
    it.getModData          = function(self) return priv.modData end
    it.getContainer        = function(self) return priv.container end
    -- Exposed for mocks that manage the back-ref when AddItem/Remove run.
    it._setContainer       = function(self, c) priv.container = c end
    it.getWorldItem        = function(self) return priv.worldItem end
    it.setWorldItem        = function(self, v)
        priv.setWorldItemCount = priv.setWorldItemCount + 1
        priv.worldItem = v
    end
    it.IsWeapon            = function(self) return priv.isWeapon end
    it.isFavorite          = function(self) return priv.favorite end
    it.setFavorite         = function(self, v) priv.favorite = v end
    it.getCurrentUsesFloat = function(self) return priv.uses end
    it.setUsedDelta        = function(self, v) priv.uses = v end
    it.setJobDelta         = function(self, v)
        priv.setJobDeltaCount = priv.setJobDeltaCount + 1
        priv.jobDelta = v
    end
    it.setJobType          = function(self, v) priv.jobType = v end
    -- Introspection for tests. Underscore prefix = "test hook, not production".
    it._private = priv
    return it
end

--- IsoWorldInventoryObject fixture. Verified against
--- zombie/iso/objects/IsoWorldInventoryObject.java surface + ISGrabItemAction
--- / ISDropWorldItemAction's usage patterns.
---
---@param innerItem table  The mock InventoryItem this wraps
---@param square    table  The mock IsoGridSquare it lives on
function Fixtures.worldItem(innerItem, square)
    local priv = {
        item = innerItem, square = square,
        rotation = 0, ignoreRemoveSandbox = false, extendedPlacement = false,
        removeFromWorldCount    = 0,
        removeFromSquareCount   = 0,
        setSquareNilCount       = 0,
        transmitCompleteCount   = 0,
        setIgnoreRemoveSandboxCount = 0,
    }
    local w = { _type = "IsoWorldInventoryObject" }
    w.getItem   = function(self) return priv.item end
    w.getSquare = function(self) return priv.square end
    w.getX      = function(self) return priv.square and priv.square:getX() or 0 end
    w.getY      = function(self) return priv.square and priv.square:getY() or 0 end
    w.getZ      = function(self) return priv.square and priv.square:getZ() or 0 end
    w.getObjectIndex = function(self)
        if not priv.square then return -1 end
        local objs = priv.square:getObjects()
        for i = 0, objs:size() - 1 do
            if objs:get(i) == self then return i end
        end
        return -1
    end
    w.removeFromWorld = function(self)
        priv.removeFromWorldCount = priv.removeFromWorldCount + 1
    end
    w.removeFromSquare = function(self)
        priv.removeFromSquareCount = priv.removeFromSquareCount + 1
    end
    w.setSquare = function(self, v)
        if v == nil then priv.setSquareNilCount = priv.setSquareNilCount + 1 end
        priv.square = v
    end
    w.setWorldZRotation = function(self, r) priv.rotation = r end
    w.setIgnoreRemoveSandbox = function(self, flag)
        priv.setIgnoreRemoveSandboxCount = priv.setIgnoreRemoveSandboxCount + 1
        priv.ignoreRemoveSandbox = flag
    end
    w.setExtendedPlacement = function(self, flag) priv.extendedPlacement = flag end
    w.transmitCompleteItemToClients = function(self)
        priv.transmitCompleteCount = priv.transmitCompleteCount + 1
    end
    w._private = priv
    return w
end

--- ItemContainer fixture. Verified against zombie/inventory/ItemContainer.java.
---
--- Mimics the *observable* side effects of the real Java class:
---   - AddItem mirrors line 450-487: rejects dupe IDs with "already has id"
---     semantics (returns existing), sets item.container back-ref, fires
---     dirty flag, calls flagForHotSave if parent present.
---   - DoRemoveItem mirrors line 2062-2085: removes from list, clears back-ref.
---   - containsID mirrors line 3162-3171: scans items list linearly.
---   - getItemById mirrors line 3369-3385: scans + recurses into nested
---     InventoryContainer items.
---
---@param opts table|nil Overrides: parent, containingItem, typeName,
---                      capacity, weightReduction, hasRoom (forced boolean)
function Fixtures.container(opts)
    opts = opts or {}
    local priv = {
        items             = {},
        itemsList         = nil,
        parent            = opts.parent,
        containingItem    = opts.containingItem,
        typeName          = opts.typeName or "none",
        capacity          = opts.capacity or 50,
        weightReduction   = opts.weightReduction or 0,
        hasRoomOverride   = opts.hasRoom,   -- nil = compute from weight
        explored          = false,
        drawDirtyCount    = 0,
        dirtyCount        = 0,
        flagForHotSaveCount = 0,
    }
    local c = { _type = "ItemContainer" }
    c.getType              = function(self) return priv.typeName end
    c.getParent            = function(self) return priv.parent end
    c.getContainingItem    = function(self) return priv.containingItem end
    c.getCapacity          = function(self) return priv.capacity end
    c.setCapacity          = function(self, v) priv.capacity = v end
    c.getEffectiveCapacity = function(self, chr) return priv.capacity end
    c.getWeightReduction   = function(self) return priv.weightReduction end
    c.setWeightReduction   = function(self, v) priv.weightReduction = v end
    c.getCapacityWeight    = function(self)
        local w = 0
        for _, it in ipairs(priv.items) do
            if it.getActualWeight then w = w + it:getActualWeight() end
        end
        return w
    end
    c.hasRoomFor = function(self, chr, itemOrWeight)
        if priv.hasRoomOverride ~= nil then return priv.hasRoomOverride end
        local add = type(itemOrWeight) == "number" and itemOrWeight
            or (itemOrWeight and itemOrWeight.getActualWeight
                and itemOrWeight:getActualWeight() or 0)
        return self:getCapacityWeight() + add <= priv.capacity
    end
    c.contains = function(self, item)
        for _, it in ipairs(priv.items) do if it == item then return true end end
        return false
    end
    c.containsID = function(self, id)
        for _, it in ipairs(priv.items) do
            if it.getID and it:getID() == id then return true end
        end
        return false
    end
    c.getItemWithID = function(self, id)
        for _, it in ipairs(priv.items) do
            if it.getID and it:getID() == id then return it end
        end
        return nil
    end
    c.getItemById = function(self, id)
        -- Mirrors Java ItemContainer.getItemById (recurses into
        -- InventoryContainer items, then their inner containers).
        for _, it in ipairs(priv.items) do
            if it.getID and it:getID() == id then return it end
            if it.getItemContainer then
                local inner = it:getItemContainer()
                if inner and inner.getItemById then
                    local nested = inner:getItemById(id)
                    if nested then return nested end
                end
            end
        end
        return nil
    end
    c.AddItem = function(self, item)
        -- Dupe guard matching ItemContainer.java:453-455. Note: real PZ prints
        -- "Error, container already has id" here. The mock silently returns
        -- the existing item so a test that sets up a bad state still sees
        -- the return value, but the count of items stays correct (no dupe).
        if item and item.getID and self:containsID(item:getID()) then
            return self:getItemWithID(item:getID())
        end
        if item and item._setContainer then
            local prev = item:getContainer()
            if prev and prev ~= self and prev.DoRemoveItem then
                prev:DoRemoveItem(item)
            end
            item:_setContainer(self)
        end
        table.insert(priv.items, item)
        priv.drawDirtyCount = priv.drawDirtyCount + 1
        if priv.parent then priv.dirtyCount = priv.dirtyCount + 1 end
        if priv.parent then priv.flagForHotSaveCount = priv.flagForHotSaveCount + 1 end
        return item
    end
    c.addItem        = c.AddItem
    c.DoAddItemBlind = c.AddItem
    c.Remove = function(self, item)
        for i, it in ipairs(priv.items) do
            if it == item then
                table.remove(priv.items, i)
                if it._setContainer then it:_setContainer(nil) end
                priv.drawDirtyCount = priv.drawDirtyCount + 1
                if priv.parent then priv.dirtyCount = priv.dirtyCount + 1 end
                return
            end
        end
    end
    c.DoRemoveItem = c.Remove
    c.getItems = function(self)
        if not priv.itemsList then priv.itemsList = makeJavaList(priv.items) end
        return priv.itemsList
    end
    c.setDrawDirty        = function(self, v) priv.drawDirtyCount = priv.drawDirtyCount + 1 end
    c.isDrawDirty         = function(self) return priv.drawDirtyCount > 0 end
    c.setExplored         = function(self, v) priv.explored = v end
    c.isExistYet          = function(self) return true end
    c.isItemAllowed       = function(self, item) return true end
    c.isInside            = function(self, item) return self:contains(item) end
    c.isInCharacterInventory = function(self, chr)
        return priv.parent and priv.parent._type == "IsoPlayer"
    end
    c.setHasBeenLooted    = function(self, v) end
    c._private = priv
    return c
end

--- IsoGridSquare fixture. Verified against zombie/iso/IsoGridSquare.java.
---
--- CRITICAL FIDELITY POINT: the 4-arg AddWorldInventoryItem(item, x, y, h)
--- overload calls (item, x, y, h, transmit=TRUE), which internally fires
--- transmitCompleteItemToClients. This mock reproduces that behaviour so
--- tests that pass only 4 args observe the SAME double-broadcast risk the
--- real engine has — that's how the v2.1.4-mid-session bug got caught.
---
---@param x number
---@param y number
---@param z number
function Fixtures.square(x, y, z)
    local priv = {
        x = x or 0, y = y or 0, z = z or 0,
        objects = {}, worldObjects = {},
        objectsList = nil, worldObjectsList = nil,
        transmitRemoveCount = 0,
        transmitRemoveArgs  = {},
        addWorldInvCalls    = {},
    }
    local sq = { _type = "IsoGridSquare" }
    sq.getX = function(self) return priv.x end
    sq.getY = function(self) return priv.y end
    sq.getZ = function(self) return priv.z end
    sq.getApparentZ = function(self, xf, yf) return priv.z end
    sq.isAdjacentTo = function(self, other) return true end
    sq.isBlockedTo  = function(self, other) return false end
    sq.getObjects = function(self)
        if not priv.objectsList then priv.objectsList = makeJavaList(priv.objects) end
        return priv.objectsList
    end
    sq.getWorldObjects = function(self)
        if not priv.worldObjectsList then priv.worldObjectsList = makeJavaList(priv.worldObjects) end
        return priv.worldObjectsList
    end
    sq.transmitRemoveItemFromSquare = function(self, obj)
        priv.transmitRemoveCount = priv.transmitRemoveCount + 1
        table.insert(priv.transmitRemoveArgs, obj)
        -- Mirrors IsoGridSquare.transmitRemoveItemFromSquare side effect —
        -- on server the object is pulled from objects/worldObjects in
        -- RemoveItemFromSquarePacket.removeItemFromMap (line 162-163).
        for i, o in ipairs(priv.objects) do
            if o == obj then table.remove(priv.objects, i); break end
        end
        for i, o in ipairs(priv.worldObjects) do
            if o == obj then table.remove(priv.worldObjects, i); break end
        end
    end
    sq.removeWorldObject = function(self, obj)
        for i, o in ipairs(priv.worldObjects) do
            if o == obj then table.remove(priv.worldObjects, i); break end
        end
        if obj.removeFromWorld  then obj:removeFromWorld()  end
        if obj.removeFromSquare then obj:removeFromSquare() end
    end
    sq.AddWorldInventoryItem = function(self, item, xf, yf, h, transmit)
        local call = {
            item = item, x = xf, y = yf, h = h, transmit = transmit,
            argCount = (transmit == nil) and 4 or 5,
        }
        table.insert(priv.addWorldInvCalls, call)
        local wi = Fixtures.worldItem(item, self)
        if item.setWorldItem then item:setWorldItem(wi) end
        -- Real Java 4-arg overload defaults transmit=true and calls
        -- transmitCompleteItemToClients internally. Reproducing that is
        -- what lets the double-broadcast regression test catch a mod that
        -- calls the 4-arg form and ALSO manually transmits.
        if transmit == nil or transmit == true then
            wi:transmitCompleteItemToClients()
        end
        table.insert(priv.worldObjects, wi)
        table.insert(priv.objects, wi)
        return item
    end
    sq.AddSpecialObject       = function(self, obj, idx) table.insert(priv.objects, obj) end
    sq.RecalcProperties       = function(self) end
    sq.RecalcAllWithNeighbours = function(self, b) end
    sq.getBuilding            = function(self) return nil end
    sq._private = priv
    return sq
end

--- IsoPlayer fixture. Verified against zombie/characters/IsoPlayer.java +
--- zombie/characters/IsoGameCharacter.java (parent class).
---
---@param opts table|nil Overrides: onlineId, playerNum, square,
---                      instantActions, fullName
function Fixtures.player(opts)
    opts = opts or {}
    local priv = {
        onlineId         = opts.onlineId       or 1,
        playerNum        = opts.playerNum      or 0,
        square           = opts.square,
        inventory        = nil,
        primary          = nil,
        secondary        = nil,
        fullName         = opts.fullName       or "Test Player",
        instantActions   = opts.instantActions or false,
        vehicle          = nil,
        seated           = false,
        farming          = false,
        asleep           = false,
        shouldTurn       = false,
        setPrimaryCount     = 0,
        setSecondaryCount   = 0,
        removeFromHandsCount = 0,
        removeAttachedItemCount = 0,
    }
    local p = { _type = "IsoPlayer" }
    p.getOnlineID      = function(self) return priv.onlineId end
    p.getPlayerNum     = function(self) return priv.playerNum end
    p.getCurrentSquare = function(self) return priv.square end
    p.getSquare        = function(self) return priv.square end
    p.setCurrentSquare = function(self, sq) priv.square = sq end
    p.getX             = function(self) return priv.square and priv.square:getX() or 0 end
    p.getY             = function(self) return priv.square and priv.square:getY() or 0 end
    p.getZ             = function(self) return priv.square and priv.square:getZ() or 0 end
    p.getInventory     = function(self) return priv.inventory end
    p.setInventory     = function(self, inv) priv.inventory = inv end
    p.getPrimaryHandItem   = function(self) return priv.primary end
    p.getSecondaryHandItem = function(self) return priv.secondary end
    p.setPrimaryHandItem = function(self, item)
        priv.setPrimaryCount = priv.setPrimaryCount + 1
        priv.primary = item
    end
    p.setSecondaryHandItem = function(self, item)
        priv.setSecondaryCount = priv.setSecondaryCount + 1
        priv.secondary = item
    end
    p.isEquipped  = function(self, item)
        return priv.primary == item or priv.secondary == item
    end
    p.removeFromHands = function(self, item)
        priv.removeFromHandsCount = priv.removeFromHandsCount + 1
        if priv.primary == item then priv.primary = nil end
        if priv.secondary == item then priv.secondary = nil end
        return true
    end
    p.removeAttachedItem = function(self, item)
        priv.removeAttachedItemCount = priv.removeAttachedItemCount + 1
    end
    p.removeWornItem     = function(self, item, b) end
    p.hasTrait           = function(self, trait) return (opts.traits or {})[trait] == true end
    p.getVehicle         = function(self) return priv.vehicle end
    p.isSeatedInVehicle  = function(self) return priv.seated end
    p.isFarming          = function(self) return priv.farming end
    p.setIsFarming       = function(self, b) priv.farming = b end
    p.isAsleep           = function(self) return priv.asleep end
    p.shouldBeTurning    = function(self) return priv.shouldTurn end
    p.isTimedActionInstant = function(self) return priv.instantActions end
    p.isImpactFromBehind = function(self) return false end
    p.getBodyDamage      = function(self)
        return { RestoreToFullHealth = function() end }
    end
    p.getFullName        = function(self) return priv.fullName end
    p.setMetabolicTarget = function(self, v) end
    -- Auto-create inventory so `player:getInventory()` works out of the box.
    priv.inventory = Fixtures.container({ parent = p, typeName = "none" })
    p._private = priv
    return p
end

--- Network spy. Patches global send* / sync* functions to record every call.
--- Callers MUST pair :install() with :uninstall() (or let Fixtures.world()
--- manage it).
function Fixtures.networkSpy()
    local spy = { _calls = {}, _saved = {} }
    function spy:reset() self._calls = {} end
    function spy:record(kind, args) table.insert(self._calls, { kind = kind, args = args }) end
    function spy:count(kind)
        local n = 0
        for _, c in ipairs(self._calls) do if c.kind == kind then n = n + 1 end end
        return n
    end
    function spy:callsFor(kind)
        local r = {}
        for _, c in ipairs(self._calls) do
            if c.kind == kind then table.insert(r, c.args) end
        end
        return r
    end
    function spy:total() return #self._calls end
    function spy:install()
        local names = {
            "sendClientCommand", "sendServerCommand",
            "sendAddItemToContainer", "sendRemoveItemFromContainer",
            "syncItemModData", "syncHandWeaponFields", "syncItemFields",
            "transmitPlayerModData",
        }
        for _, n in ipairs(names) do
            self._saved[n] = _G[n]
            _G[n] = (function(kind)
                return function(...) spy:record(kind, { ... }) end
            end)(n)
        end
    end
    function spy:uninstall()
        for name, fn in pairs(self._saved) do _G[name] = fn end
        self._saved = {}
    end
    return spy
end

--- Faithful mock of the container broadcast helpers.
---
--- WHY THIS EXISTS: `Fixtures.networkSpy` records `sendAddItemToContainer` /
--- `sendRemoveItemFromContainer` calls but says nothing about whether the
--- packet was actually SENT. In real PZ both methods
--- (GameServer.java:2391 and :2451) are a three-branch if/elseif chain with
--- NO else:
---
---   1. container:getCharacter() is an IsoPlayer  -> send to that player
---   2. container:getParent() ~= nil              -> sendToRelative(parent x,y)
---   3. container.inventoryContainer:getWorldItem() ~= nil
---                                                -> sendToRelative(item x,y)
---
--- A container matching none of the three is UNADDRESSABLE and the packet is
--- silently dropped — no error, no log. That is a live MP failure mode for
--- any container nested inside a vehicle part or a world object: their inner
--- containers are built with the no-arg `new ItemContainer()` so `parent` is
--- nil, `getCharacter()` (ItemContainer.java:3314) walks up and terminates at
--- the non-character owner, and a nested bag has no world item.
---
--- Branch 3 is narrower than it looks, and the narrowing is what matters:
--- `inventoryContainer` is set for every InventoryContainer (assigned in the
--- constructor at InventoryContainer.java:36 on a field-initialised
--- ItemContainer, and `load()` reuses that same object rather than replacing
--- it — so it survives save/load). What fails is `getWorldItem()`: it is
--- non-nil only while the containing item is lying on the ground as an
--- IsoWorldInventoryObject. A bag sitting INSIDE a trunk or a shelf has no
--- world item, so branch 3 misses for exactly the nested case that branches
--- 1 and 2 also miss.
---
--- A recording-only stub makes all of that invisible and lets a test go green
--- against code that never syncs anything. Use this spy whenever the code
--- under test performs server-authoritative container moves.
---
--- Fixture requirements: containers should implement `getCharacter()` and
--- `getParent()` and expose an `inventoryContainer` field to be scored
--- accurately. A missing method is treated as "not addressable via that
--- branch", which matches the Java null checks.
---
--- Callers MUST pair :install() with :uninstall().
function Fixtures.containerSyncSpy()
    local spy = { _calls = {}, _saved = {}, _hadKey = {} }

    --- Mirror of the Java dispatch chain. Returns the branch that would carry
    --- the packet, or nil when the container is unaddressable.
    local function routeFor(container)
        if not container then return nil end
        local chr = container.getCharacter and container:getCharacter()
        if chr then
            local isPlayer = chr._type == "IsoPlayer"
            if not isPlayer and instanceof then
                isPlayer = instanceof(chr, "IsoPlayer")
            end
            if isPlayer then return "character" end
        end
        if container.getParent and container:getParent() ~= nil then
            return "parent"
        end
        local ic = container.inventoryContainer
        if ic and ic.getWorldItem and ic:getWorldItem() ~= nil then
            return "worldItem"
        end
        return nil
    end
    spy.routeFor = function(_, container) return routeFor(container) end

    function spy:reset() self._calls = {} end
    function spy:record(kind, container, item)
        local route = routeFor(container)
        table.insert(self._calls, {
            kind = kind, container = container, item = item,
            route = route, delivered = route ~= nil,
        })
    end

    --- Every recorded call of `kind` (nil = all kinds).
    function spy:callsFor(kind)
        local r = {}
        for _, c in ipairs(self._calls) do
            if kind == nil or c.kind == kind then table.insert(r, c) end
        end
        return r
    end
    --- Count of calls that would actually reach a client.
    function spy:deliveredCount(kind)
        local n = 0
        for _, c in ipairs(self:callsFor(kind)) do
            if c.delivered then n = n + 1 end
        end
        return n
    end
    --- Count of calls silently swallowed by the unaddressable-container hole.
    function spy:droppedCount(kind)
        local n = 0
        for _, c in ipairs(self:callsFor(kind)) do
            if not c.delivered then n = n + 1 end
        end
        return n
    end
    --- True when at least one `kind` packet naming `item` reached a client.
    function spy:deliveredFor(kind, item)
        for _, c in ipairs(self:callsFor(kind)) do
            if c.item == item and c.delivered then return true end
        end
        return false
    end
    function spy:total() return #self._calls end

    function spy:install()
        local handlers = {
            sendAddItemToContainer = function(container, item)
                spy:record("add", container, item)
            end,
            sendRemoveItemFromContainer = function(container, item)
                spy:record("remove", container, item)
            end,
            -- GameServer.sendItemsInContainer(IsoObject, ItemContainer) — the
            -- anchored full-container resync. It takes an explicit IsoObject
            -- so its DISPATCH has no addressability hole. Its client handler
            -- does though: AddInventoryItemToContainerPacket.processClient
            -- (:87-90) skips any item whose id the destination already holds
            -- and logs "Error: Dupe item ID". `applied` records whether the
            -- client would actually change state, which is the thing that
            -- matters and the thing a send-only stub hides.
            sendItemsInContainer = function(anchor, container)
                local applied, skipped = 0, 0
                if container and container.getItems then
                    local items = container:getItems()
                    for i = 0, items:size() - 1 do
                        local it = items:get(i)
                        -- Modelled against the RECEIVING side: a client whose
                        -- container already holds this id discards the entry.
                        if it and container.containsID and container:containsID(it:getID()) then
                            skipped = skipped + 1
                        else
                            applied = applied + 1
                        end
                    end
                end
                table.insert(spy._calls, {
                    kind = "resync", container = container, anchor = anchor,
                    route = "anchor", delivered = anchor ~= nil,
                    applied = applied, skipped = skipped,
                })
            end,
            -- GameServer.sendReplaceItemInContainer — same three-branch
            -- dispatch as add/remove, but its client handler
            -- (ReplaceInventoryItemInContainerPacket.processClient:67-69)
            -- does removeItemWithID then addItem with NO dedup guard, so it
            -- always applies. This is how a nested container's contents can
            -- actually be refreshed on a client.
            sendReplaceItemInContainer = function(container, oldItem, newItem)
                local route = routeFor(container)
                table.insert(spy._calls, {
                    kind = "replace", container = container,
                    item = newItem, oldItem = oldItem,
                    route = route, delivered = route ~= nil, applied = 1,
                })
            end,
            -- Vanilla's Commands.ui.DirtyUI (client ServerCommands.lua:138)
            -- runs ISInventoryPage.dirtyUI() -> refreshBackpacks(), which
            -- RE-RESOLVES each panel's container list. Recorded separately
            -- because a `replace` rebinds the container object, so data
            -- correctness and panel correctness are two different questions
            -- and a test should be able to assert both.
            sendServerCommand = function(a, b, c, d)
                -- 4-arg targeted form is (player, module, command, args);
                -- the 3-arg broadcast form is (module, command, args).
                local player, module, command
                if type(a) == "string" then
                    player, module, command = nil, a, b
                else
                    player, module, command = a, b, c
                end
                table.insert(spy._calls, {
                    kind = "servercommand", player = player,
                    module = module, command = command,
                    delivered = true, applied = 1,
                })
            end,
        }
        for name, fn in pairs(handlers) do
            self._hadKey[name] = _G[name] ~= nil
            self._saved[name] = _G[name]
            _G[name] = fn
        end
    end
    function spy:uninstall()
        for name, had in pairs(self._hadKey) do
            _G[name] = had and self._saved[name] or nil
        end
        self._saved, self._hadKey = {}, {}
    end
    return spy
end

--- Event spy. Captures triggerEvent / LuaEventManager:triggerEvent.
function Fixtures.eventSpy()
    local spy = { _events = {}, _savedGlobal = nil, _savedLEM = nil }
    function spy:reset() self._events = {} end
    function spy:record(name, ...) table.insert(self._events, { name = name, args = { ... } }) end
    function spy:count(name)
        local n = 0
        for _, e in ipairs(self._events) do if e.name == name then n = n + 1 end end
        return n
    end
    function spy:install()
        self._savedGlobal = _G.triggerEvent
        _G.triggerEvent = function(name, ...) spy:record(name, ...) end
        if LuaEventManager and LuaEventManager.triggerEvent then
            self._savedLEM = LuaEventManager.triggerEvent
            LuaEventManager.triggerEvent = function(self, name, ...) spy:record(name, ...) end
        end
    end
    function spy:uninstall()
        if self._savedGlobal then _G.triggerEvent = self._savedGlobal end
        if self._savedLEM and LuaEventManager then
            LuaEventManager.triggerEvent = self._savedLEM
        end
        self._savedGlobal, self._savedLEM = nil, nil
    end
    return spy
end

--- Top-level world fixture. Wires getCell() → an in-memory cell that holds
--- fixture squares, auto-installs network + event spies, and cleans up
--- after the test via :teardown().
---
---@param opts table|nil { install = false to skip auto-install }
function Fixtures.world(opts)
    opts = opts or {}
    local world = {
        _squares    = {},
        _players    = {},
        network     = Fixtures.networkSpy(),
        events      = Fixtures.eventSpy(),
        _installed  = false,
        _saved      = {},
    }
    function world:square(x, y, z)
        local key = string.format("%d,%d,%d", x, y, z)
        if not self._squares[key] then self._squares[key] = Fixtures.square(x, y, z) end
        return self._squares[key]
    end
    function world:player(popts)
        local p = Fixtures.player(popts)
        table.insert(self._players, p)
        return p
    end
    function world:install()
        if self._installed then return end
        self._installed = true
        self._saved.getCell       = _G.getCell
        self._saved.getWorld      = _G.getWorld
        self._saved.getGameTime   = _G.getGameTime
        self._saved.getTimestampMs = _G.getTimestampMs
        local cell = {
            getGridSquare = function(_, x, y, z)
                return world._squares[string.format("%d,%d,%d", x, y, z)]
            end,
        }
        _G.getCell  = function() return cell end
        _G.getWorld = function() return { currentCell = cell } end
        _G.getGameTime = _G.getGameTime or function()
            return { getWorldAgeHours = function() return 0 end }
        end
        _G.getTimestampMs = _G.getTimestampMs or function() return 0 end
        self.network:install()
        self.events:install()
    end
    function world:teardown()
        self.network:uninstall()
        self.events:uninstall()
        for name, fn in pairs(self._saved) do _G[name] = fn end
        self._saved = {}
        self._installed = false
    end
    if opts.install ~= false then world:install() end
    return world
end

--- Temporarily override SandboxVars entries for the duration of fn. Restores
--- prior values (and deletes keys that didn't exist before) on return.
---
---@param namespace string  e.g. "SaucedCarts", "VorpallySauced"
---@param overrides table   { key = value, ... }
---@param fn function       body to run with overrides in effect
function Fixtures.withSandbox(namespace, overrides, fn)
    SandboxVars = SandboxVars or {}
    SandboxVars[namespace] = SandboxVars[namespace] or {}
    local target = SandboxVars[namespace]
    local saved, hadKey = {}, {}
    for k, v in pairs(overrides) do
        hadKey[k] = target[k] ~= nil
        saved[k] = target[k]
        target[k] = v
    end
    local ok, result = pcall(fn)
    for k, _ in pairs(overrides) do
        if hadKey[k] then target[k] = saved[k]
        else target[k] = nil end
    end
    if not ok then error(result) end
    return result
end

--- BaseVehicle fixture — the methods a command provider gates on (engine / lights
--- / doors / locks / parts). Focused on what's needed to exercise the palette's
--- vehicle gating (lock-aware doors, hotwire, heater, lightbar), not a full sim.
---
---@param opts table|nil Overrides (all optional, sensible defaults):
---  name, driver, engineWorking, engineRunning, engineStarted, hotwired,
---  keysInIgnition, keyId, headlights, headlightsOn, horn, lightbar, stopped,
---  anyDoorLocked, passengerCount, heaterActive (nil = no heater part),
---  canUnlock, canLock, and door = { id, open, locked, hasItem }.
function Fixtures.vehicle(opts)
    opts = opts or {}
    local doorOpts = opts.door or {}
    local door = {
        _open = doorOpts.open or false,
        _locked = doorOpts.locked or false,
    }
    door.isOpen   = function(self) return self._open end
    door.isLocked = function(self) return self._locked end
    door.setLocked = function(self, v) self._locked = v end

    local doorPart = { _type = "VehiclePart" }
    doorPart.getId            = function(self) return doorOpts.id or "DoorFrontLeft" end
    doorPart.getDoor          = function(self) return door end
    doorPart.getInventoryItem = function(self)
        if doorOpts.hasItem == false then return nil end
        return { _type = "InventoryItem" }
    end
    doorPart.getVehicle = function(self) return opts._vehicle end

    local heater = nil
    if opts.heaterActive ~= nil then
        heater = { _type = "VehiclePart" }
        heater.getModData = function(self) return { active = opts.heaterActive } end
    end

    local v = { _type = "BaseVehicle" }
    opts._vehicle = v
    local parts = {}   -- populated below from opts.parts; getPartById searches it
    v.isDriver         = function(self, p) return opts.driver ~= false end
    v.isEngineWorking  = function(self) return opts.engineWorking ~= false end
    v.isEngineRunning  = function(self) return opts.engineRunning or false end
    v.isEngineStarted  = function(self) return opts.engineStarted or false end
    v.isHotwired       = function(self) return opts.hotwired or false end
    v.isKeysInIgnition = function(self) return opts.keysInIgnition or false end
    v.getKeyId         = function(self) return opts.keyId or 1 end
    v.hasHeadlights    = function(self) return opts.headlights or false end
    v.getHeadlightsOn  = function(self) return opts.headlightsOn or false end
    v.hasHorn          = function(self) return opts.horn or false end
    v.hasLightbar      = function(self) return opts.lightbar or false end
    v.isAnyDoorLocked  = function(self) return opts.anyDoorLocked or false end
    v.isStopped        = function(self) return opts.stopped ~= false end
    v.getPartById      = function(self, id)
        if id == "Heater" then return heater end
        for _, pt in ipairs(parts) do if pt:getId() == id then return pt end end
        return nil
    end
    v.getUseablePart   = function(self, p) return doorPart end
    v.canUnlockDoor    = function(self, part, p) return opts.canUnlock or false end
    v.canLockDoor      = function(self, part, p) return opts.canLock or false end
    v.getScript        = function(self) return { getPassengerCount = function() return opts.passengerCount or 2 end } end
    v.getId            = function(self) return opts.id or 100 end

    -- Parts (for the mechanics provider). opts.parts = list of specs:
    --   { id, category, itemType={fulltypes}, installed, tables={install=,uninstall=},
    --     canInstall, canUninstall, fuel, window={openable,destroyed,open} }
    for _, spec in ipairs(opts.parts or {}) do
        local pt = { _type = "VehiclePart", _spec = spec }
        pt.getId        = function(self) return spec.id or "Part" end
        pt.getCategory  = function(self) return spec.category or "engine" end
        pt.getItemType  = function(self)
            if spec.itemType == nil then return nil end
            return makeJavaList(spec.itemType)
        end
        pt.getInventoryItem = function(self)
            if spec.installed then return { _type = "InventoryItem" } end
            return nil
        end
        pt.getTable     = function(self, name) return spec.tables and spec.tables[name] or nil end
        pt.getContainerContentAmount = function(self) return spec.fuel or 0 end
        pt.getWindow    = function(self)
            if not spec.window then return nil end
            local wspec = spec.window
            return {
                isOpenable  = function() return wspec.openable ~= false end,
                isDestroyed = function() return wspec.destroyed or false end,
                isOpen      = function() return wspec.open or false end,
            }
        end
        parts[#parts + 1] = pt
    end
    v.getPartCount     = function(self) return #parts end
    v.getPartByIndex   = function(self, i) return parts[i + 1] end
    v.canInstallPart   = function(self, pl, part) return part._spec.canInstall ~= false end
    v.canUninstallPart = function(self, pl, part) return part._spec.canUninstall ~= false end

    v._door = door
    v._doorPart = doorPart
    v._parts = parts
    return v
end

-- ============================================================================
-- SKIP SUPPORT
-- ============================================================================
-- A test function that returns `PZTestKit.SKIP` (or a table with
-- `__pztestkit_skip = true`) is recorded as SKIPPED rather than passed or
-- failed. This lets mods mark tests that only work in one environment (e.g.,
-- offline-only tests that synthesize a fake ISHandcraftAction, or in-game-
-- only tests that need real game state) without lying about the result.

PZTestKit.SKIP = { __pztestkit_skip = true, message = "skipped" }

--- Return from a test function to mark it skipped. Optional reason string
--- shows up in test output and JUnit XML.
function PZTestKit.skip(reason)
    return { __pztestkit_skip = true, message = reason or "skipped" }
end

--- Convenience gate: register a test that auto-skips when running in real PZ
--- (no require resolver present), and runs normally under pz-test-kit.
---
--- The environment fingerprint is `_pz_module_sources`, a global populated
--- by pz-test-kit's require_resolver.lua and nil in real PZ.
---
---@param runner VorpallySauced.TestRunner-style runner with .registerSync
---@param name string Test name
---@param fn function Test body (runs only when offline)
function PZTestKit.skipInGame(runner, name, fn)
    if not runner or not runner.registerSync then
        error("PZTestKit.skipInGame: first arg must be a TestRunner-like object", 2)
    end
    runner.registerSync(name, function(self)
        if _pz_module_sources == nil then
            return PZTestKit.skip("offline-only test")
        end
        return fn(self)
    end)
end
