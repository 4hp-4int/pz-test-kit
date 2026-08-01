-- Proof: clipSize affix is now a PERCENTAGE of the mod's live mag — small
-- mags get a small bump, big drums get a real boost (not flat +3).
local V, WD, SM = VorpallySauced, VorpallySauced.WeaponData, VorpallySauced.StatModifiers
local sfx, pct
for i, s in ipairs(V.FirearmSuffixes) do
    if s.stat == "clipSize" then sfx, pct = i, s.value break end
end
local o = { string.format("clipSize suffix #%d pct=%s", sfx, tostring(pct)) }

-- a real MarzGuns weapon per magazine size, attach mag as Clip, affix, reapply
local items = getScriptManager():getAllItems()
local shown = 0
for i = 0, items:size() - 1 do
    local sc = items:get(i)
    if sc:getModuleName() == "MarzGuns" and shown < 8 then
        local ft = "MarzGuns." .. sc:getName()
        local ok, w = pcall(instanceItem, ft)
        if ok and w and w.isRanged and w:isRanged() and WD.isValidFirearm(w)
           and (w:getMagazineType() or "") ~= "" then
            local okm, mag = pcall(instanceItem, w:getMagazineType())
            if okm and mag and instanceof(mag, "WeaponPart") then
                local cap = mag:getMaxAmmo()
                if cap and cap > 0 then
                    pcall(function() if w.canAttachWeaponPart==nil or w:canAttachWeaponPart(mag) then w:attachWeaponPart(mag) end end)
                    w:setMaxAmmo(cap)
                    local d = WD.getOrCreateModData(w); d.isFirearm=true; d.suffixId=sfx; d.dynamicCapacity=nil
                    WD.rt(d.weaponId).appliedClipBonus = 0
                    local expectBonus = WD.clipSizePctBonus(cap, pct)
                    SM.reapplyUpgrades(w)
                    o[#o+1] = string.format("%-14s magCap=%-3d  +%d (%.0f%%)  -> %d  %s",
                        sc:getName(), cap, expectBonus, pct*100, w:getMaxAmmo(),
                        (w:getMaxAmmo() == cap + expectBonus) and "OK" or
                        ("**FAIL want "..(cap+expectBonus).."**"))
                    shown = shown + 1
                end
            end
        end
    end
end
return table.concat(o, "\n")
