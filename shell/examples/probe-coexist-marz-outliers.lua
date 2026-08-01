-- Characterize the MarzGuns Clip-path coexistence outliers: which weapons,
-- reload type, magType, script clipSize/maxAmmo, attach success, result.
local V, WD, SM = VorpallySauced, VorpallySauced.WeaponData, VorpallySauced.StatModifiers
local clipSfx, A
for i, s in ipairs(V.FirearmSuffixes) do
    if s.stat == "clipSize" then clipSfx, A = i, (s.value or 0) break end
end
local items = getScriptManager():getAllItems()
local o, okN, badN = {}, 0, 0
for i = 0, items:size() - 1 do
    local sc = items:get(i)
    if sc:getModuleName() == "MarzGuns" then
        local ft = "MarzGuns." .. sc:getName()
        local ok, w = pcall(instanceItem, ft)
        if ok and w and w.isRanged and w:isRanged() and WD.isValidFirearm(w)
           and w.getMagazineType and (w:getMagazineType() or "") ~= "" then
            local magType = w:getMagazineType()
            local okm, mag = pcall(instanceItem, magType)
            local magCap = (okm and mag and mag.getMaxAmmo and mag:getMaxAmmo()) or 0
            local d = WD.getOrCreateModData(w); d.isFirearm=true; d.suffixId=clipSfx; d.dynamicCapacity=nil
            WD.rt(d.weaponId).appliedClipBonus = 0
            local isWP = mag and instanceof(mag, "WeaponPart")
            local attached = false
            if w.attachWeaponPart and isWP then
                pcall(function() if w.canAttachWeaponPart==nil or w:canAttachWeaponPart(mag) then w:attachWeaponPart(mag); attached=true end end)
            end
            local clip = w.getWeaponPart and w:getWeaponPart("Clip")
            local clipMax = (clip and clip.getMaxAmmo and clip:getMaxAmmo()) or 0
            if magCap > 0 then w:setMaxAmmo(magCap) end
            local scrClip = w:getScriptItem() and w:getClipSize() or -1
            SM.reapplyUpgrades(w)
            local got, want = w:getMaxAmmo(), magCap + A
            if got == want then okN = okN + 1 else
                badN = badN + 1
                if #o < 20 then o[#o+1] = string.format(
                    "%s rt=%s magType=%s magCap=%d isWP=%s attached=%s clipPartMax=%d clipSize=%s -> got %d want %d",
                    sc:getName(), tostring(w:getWeaponReloadType()), magType, magCap,
                    tostring(isWP), tostring(attached), clipMax, tostring(scrClip), got, want) end
            end
        end
    end
end
table.insert(o, 1, string.format("MarzGuns Clip-path: OK=%d  OUTLIERS=%d", okN, badN))
return table.concat(o, "\n")
