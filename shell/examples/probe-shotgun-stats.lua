-- Probe: dump the current server-side view of the player's primary hand weapon.
-- Useful for diagnosing the v1.10 shotgun capacity bug in situ: is
-- appliedClipBonus right? Does maxAmmo match? Etc.
--
-- Usage (from pz-test-kit/shell):
--   ./pz-shell eval -f examples/probe-shotgun-stats.lua
--
-- Works on the first connected player. getPlayer() is client-only (returns
-- the local player, i.e. nil on dedi), so we use getOnlinePlayers() for dedi.

local p
if getOnlinePlayers then
    local online = getOnlinePlayers()
    if online and online:size() > 0 then p = online:get(0) end
end
if not p and getPlayer then p = getPlayer() end
if not p then return "no connected player (and not a SP context)" end

-- Try primary first, then first weapon in inventory (setPrimaryHandItem from
-- server-side gets overwritten by client-reported state between ticks).
local w = p:getPrimaryHandItem()
if not w then
    local items = p:getInventory():getItems()
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it and it.IsWeapon and it:IsWeapon() then w = it; break end
    end
end
if not w then return p:getUsername() .. " has no weapon (primary or inventory)" end

local data = w:getModData().VorpallySauced
if not data then return w:getName() .. ": no VPS data" end

-- Expand packed format if VorpallySauced is loaded (v1.10+).
if VorpallySauced and VorpallySauced.WeaponData and VorpallySauced.WeaponData.getModData then
    data = VorpallySauced.WeaponData.getModData(w) or data
end

local lines = {
    string.format("weapon:   %s (id=%s)", w:getName(), tostring(w:getID())),
    string.format("maxAmmo:  %s", tostring(w.getMaxAmmo and w:getMaxAmmo())),
    string.format("clipSize: %s", tostring(w.getClipSize and w:getClipSize())),
    string.format("ammo:     %s", tostring(w.getCurrentAmmoCount and w:getCurrentAmmoCount())),
    string.format("kills:    %s", tostring(data.kills)),
    string.format("prefix:   %s", tostring(data.prefixId)),
    string.format("suffix:   %s", tostring(data.suffixId)),
    string.format("bonding:  %s", tostring(data.bondingId)),
}

if VorpallySauced and VorpallySauced.WeaponData then
    local WD = VorpallySauced.WeaponData
    if WD.calculateClipSizeBonus then
        table.insert(lines, string.format("expectedBonus: %d",
            WD.calculateClipSizeBonus(w) or 0))
    end
    if WD.hasStaleFirearmStats then
        table.insert(lines, string.format("stale: %s",
            tostring(WD.hasStaleFirearmStats(w))))
    end
end

return table.concat(lines, "\n")
