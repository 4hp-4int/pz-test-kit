--[[
    PZ Test Kit — Dual-VM sync-apply dispatcher
    ============================================
    Runs in the TARGET endpoint's env after DualVMSim routes a sync message.
    Inputs (set as globals by the Java dispatcher):
        _pz_sync_weaponId  — the item ID to locate on this endpoint
        _pz_sync_payload   — table of state to apply
        _pz_sync_kind      — "moddata" | "handweapon" | "itemfields"

    For each kind, apply via the same setters the real PZ packet calls on
    receipt:
        moddata    — copy every key of payload into item:getModData(),
                     deep-copying nested tables so source-env mutations
                     after the sync don't leak across the boundary
        handweapon — call each setter from SyncHandWeaponFieldsPacket.java
                     that real PZ invokes when unpacking the packet
        itemfields — same, for SyncItemFieldsPacket.java
]]

local id      = _pz_sync_weaponId
local payload = _pz_sync_payload
local kind    = _pz_sync_kind
if not id or not payload then return end

local p = getPlayer()
if not p then return end

local inv = p:getInventory()
local item = inv and inv.getItemById and inv:getItemById(id)
if not item then item = p:getPrimaryHandItem() end
if not item then return end

local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepCopy(v) end
    return out
end

if kind == "moddata" then
    local tgtMD = item:getModData()
    if type(payload) == "table" then
        for k, v in pairs(payload) do tgtMD[k] = deepCopy(v) end
    end

elseif kind == "handweapon" then
    if type(payload) == "table" then
        if payload.currentAmmoCount ~= nil and item.setCurrentAmmoCount then item:setCurrentAmmoCount(payload.currentAmmoCount) end
        if payload.maxRange         ~= nil and item.setMaxRange         then item:setMaxRange(payload.maxRange) end
        if payload.minRangeRanged   ~= nil and item.setMinRangeRanged   then item:setMinRangeRanged(payload.minRangeRanged) end
        if payload.clipSize         ~= nil and item.setClipSize         then item:setClipSize(payload.clipSize) end
        if payload.reloadTime       ~= nil and item.setReloadTime       then item:setReloadTime(payload.reloadTime) end
        if payload.recoilDelay      ~= nil and item.setRecoilDelay      then item:setRecoilDelay(payload.recoilDelay) end
        if payload.aimingTime       ~= nil and item.setAimingTime       then item:setAimingTime(payload.aimingTime) end
        if payload.hitChance        ~= nil and item.setHitChance        then item:setHitChance(payload.hitChance) end
        if payload.minAngle         ~= nil and item.setMinAngle         then item:setMinAngle(payload.minAngle) end
        if payload.minDamage        ~= nil and item.setMinDamage        then item:setMinDamage(payload.minDamage) end
        if payload.maxDamage        ~= nil and item.setMaxDamage        then item:setMaxDamage(payload.maxDamage) end
    end

elseif kind == "itemfields" then
    if type(payload) == "table" then
        if payload.condition        ~= nil and item.setCondition        then item:setCondition(payload.condition) end
        if payload.headCondition    ~= nil and item.setHeadCondition    then item:setHeadCondition(payload.headCondition) end
        if payload.currentAmmoCount ~= nil and item.setCurrentAmmoCount then item:setCurrentAmmoCount(payload.currentAmmoCount) end
    end
end
