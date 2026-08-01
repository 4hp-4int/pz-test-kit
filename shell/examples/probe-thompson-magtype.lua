-- Inspect the connected player's equipped weapon: who/what made
-- getMagazineType() return a bare (unqualified) type that crashes vanilla
-- HandWeapon.DoTooltip's InventoryItemFactory.CreateItem.
local V, WD = VorpallySauced, VorpallySauced.WeaponData
local out = {}

local players = {}
local op = getOnlinePlayers and getOnlinePlayers()
if op then for i = 0, op:size() - 1 do players[#players+1] = op:get(i) end end
if #players == 0 and getPlayer and getPlayer() then players[1] = getPlayer() end
out[#out+1] = "online players: " .. #players

for _, ply in ipairs(players) do
    local w = ply.getPrimaryHandItem and ply:getPrimaryHandItem()
    if not w or not (w.isRanged and w:isRanged()) then
        -- fall back: first firearm in inventory
        local inv = ply.getInventory and ply:getInventory()
        if inv then
            local items = inv:getItems()
            for i = 0, items:size() - 1 do
                local it = items:get(i)
                if it and it.isRanged and it:isRanged() then w = it break end
            end
        end
    end
    if w then
        local mt = w.getMagazineType and w:getMagazineType()
        local resolvable = false
        if mt then local ok, m = pcall(instanceItem, mt); resolvable = (ok and m ~= nil) end
        local sm = w.getScriptItem and w:getScriptItem()
        local md = w:getModData()
        local dyn = V.getDynamicMagazineType and V.getDynamicMagazineType(w)
        local vd = WD.getModData and WD.getModData(w)
        out[#out+1] = string.format(
            "weapon=%s | getMagazineType=%q resolvable=%s | scriptFullName=%s scriptDisplay=%s name=%s",
            tostring(w.getFullType and w:getFullType()), tostring(mt), tostring(resolvable),
            tostring(sm and sm.getFullName and sm:getFullName()),
            tostring(sm and sm.getDisplayName and sm:getDisplayName()),
            tostring(w.getName and w:getName()))
        out[#out+1] = string.format(
            "  ModData: MagazineTypeNow=%q MagzineTypeNow=%q getDynamicMagazineType=%q",
            tostring(md.MagazineTypeNow), tostring(md.MagzineTypeNow), tostring(dyn))
        out[#out+1] = string.format(
            "  VPS: scriptType=%s originalName=%s prefix=%s suffix=%s bonding=%s dynamicCapacity=%s",
            tostring(vd and vd.scriptType), tostring(vd and vd.originalName),
            tostring(vd and vd.prefixId), tostring(vd and vd.suffixId),
            tostring(vd and vd.bondingId), tostring(vd and vd.dynamicCapacity))
        local clip = w.getWeaponPart and w:getWeaponPart("Clip")
        out[#out+1] = string.format("  Clip part: %s fullType=%s maxAmmo=%s",
            tostring(clip ~= nil),
            tostring(clip and clip.getFullType and clip:getFullType()),
            tostring(clip and clip.getMaxAmmo and clip:getMaxAmmo()))
    else
        out[#out+1] = "no ranged weapon found for player"
    end
end
return table.concat(out, "\n")
