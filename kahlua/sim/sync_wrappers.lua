--[[
    PZ Test Kit — Dual-VM sync wrappers
    ====================================
    Installs pure-Lua replacements for PZ's MP sync primitives:
        syncItemModData      — replicates item:getModData() to target envs
        syncHandWeaponFields — replicates HandWeapon stat fields
        syncItemFields       — replicates InventoryItem condition & misc

    Each wrapper snapshots via the real PZ getters, then hands the snapshot
    to the Java bridge `_pz_sim_push_sync(kind, player, weaponId, payload)`
    installed by DualVMSim.

    The snapshotted field sets come from the real sync packets:
        - SyncHandWeaponFieldsPacket.java
        - SyncItemFieldsPacket.java

    If PZ adds fields to these packets, mirror them here.
]]

function syncItemModData(player, item)
    if not item then return end
    local id = item.getID and item:getID() or 0
    local md = item.getModData and item:getModData() or nil
    _pz_sim_push_sync("moddata", player, id, md)
end

function syncHandWeaponFields(player, item)
    if not item then return end
    local id = item.getID and item:getID() or 0
    local snap = {}
    if item.getCurrentAmmoCount then snap.currentAmmoCount = item:getCurrentAmmoCount() end
    if item.isContainsClip      then snap.containsClip     = item:isContainsClip() end
    if item.getMaxRange         then snap.maxRange         = item:getMaxRange() end
    if item.getMinRangeRanged   then snap.minRangeRanged   = item:getMinRangeRanged() end
    if item.getClipSize         then snap.clipSize         = item:getClipSize() end
    if item.getReloadTime       then snap.reloadTime       = item:getReloadTime() end
    if item.getRecoilDelay      then snap.recoilDelay      = item:getRecoilDelay() end
    if item.getAimingTime       then snap.aimingTime       = item:getAimingTime() end
    if item.getHitChance        then snap.hitChance        = item:getHitChance() end
    if item.getMinAngle         then snap.minAngle         = item:getMinAngle() end
    if item.getMinDamage        then snap.minDamage        = item:getMinDamage() end
    if item.getMaxDamage        then snap.maxDamage        = item:getMaxDamage() end
    _pz_sim_push_sync("handweapon", player, id, snap)
end

function syncItemFields(player, item)
    if not item then return end
    local id = item.getID and item:getID() or 0
    local snap = {}
    if item.getCondition        then snap.condition        = item:getCondition() end
    if item.getHeadCondition    then snap.headCondition    = item:getHeadCondition() end
    if item.getCurrentAmmoCount then snap.currentAmmoCount = item:getCurrentAmmoCount() end
    if item.getHaveBeenRepaired then snap.haveBeenRepaired = item:getHaveBeenRepaired() end
    _pz_sim_push_sync("itemfields", player, id, snap)
end
