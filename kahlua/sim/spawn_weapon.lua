--[[
    PZ Test Kit — Dual-VM spawnSyncedWeapon helper
    ================================================
    Runs in each endpoint's env when sim:spawnSyncedWeapon(fullType, opts)
    is called. Seeds a global `_wpn` with the same ID across server + clients
    so ID-based lookups (inv:getItemById) and ModData-sync routing agree.

    Inputs (set as globals by the Java dispatcher):
        _pz_spawn_fullType  — item fullType ("Base.Axe")
        _pz_spawn_id        — numeric ID to lock onto
        _pz_spawn_equip     — boolean; if true, also call setPrimaryHandItem

    Leaves `_wpn` nil if instanceItem returns nil (unknown fullType, etc.)
    rather than raising — tests decide how to react.
]]

local fullType = _pz_spawn_fullType
local id       = _pz_spawn_id
local equip    = _pz_spawn_equip

_wpn = instanceItem(fullType)
if not _wpn then return end

_wpn._id = id
_wpn.getID = function() return id end

local inv = getPlayer() and getPlayer():getInventory()
if inv and inv.AddItem then inv:AddItem(_wpn) end

if equip and getPlayer() and getPlayer().setPrimaryHandItem then
    getPlayer():setPrimaryHandItem(_wpn)
end
