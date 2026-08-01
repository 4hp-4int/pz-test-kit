local V, WD, SM = VorpallySauced, VorpallySauced.WeaponData, VorpallySauced.StatModifiers
local sfx, pct
for i, s in ipairs(V.FirearmSuffixes) do
    if s.stat == "clipSize" then sfx, pct = i, s.value break end
end
local o = { "suffix #"..sfx.." pct="..tostring(pct) }
for _, name in ipairs({ "M1_GARAND", "PSG1", "SVD", "M1911", "AR15", "AK47" }) do
    local w = instanceItem("MarzGuns." .. name)
    if w then
        local magType = w:getMagazineType()
        local mag = instanceItem(magType)
        local preMagMax = mag and mag.getMaxAmmo and mag:getMaxAmmo() or -1
        local isWP = mag and instanceof(mag, "WeaponPart")
        local scrMax = WD.getOriginalStat(w, "maxAmmo") or -1
        local scrClip = WD.getOriginalStat(w, "clipSize") or -1
        local attached = false
        if isWP and w.attachWeaponPart then
            pcall(function() if w.canAttachWeaponPart==nil or w:canAttachWeaponPart(mag) then w:attachWeaponPart(mag); attached=true end end)
        end
        local clip = w.getWeaponPart and w:getWeaponPart("Clip")
        local postClipMax = clip and clip.getMaxAmmo and clip:getMaxAmmo() or -1
        local effBase = WD.getEffectiveMagBase(w)
        local pctB = WD.clipSizePctBonus(effBase, pct)
        if preMagMax > 0 then w:setMaxAmmo(preMagMax) end
        local d = WD.getOrCreateModData(w); d.isFirearm=true; d.suffixId=sfx; d.dynamicCapacity=nil
        WD.rt(d.weaponId).appliedClipBonus = 0
        local preReapClip, preReapMax = w:getClipSize(), w:getMaxAmmo()
        SM.reapplyUpgrades(w)
        o[#o+1] = string.format(
            "%-10s magType=%s preMag=%d isWP=%s scrMax=%d scrClip=%d attached=%s postClip=%d effBase=%d pctB=%d | preReap clip/max=%d/%d -> final clip/max=%d/%d",
            name, magType, preMagMax, tostring(isWP), scrMax, scrClip, tostring(attached),
            postClipMax, effBase, pctB, preReapClip, preReapMax, w:getClipSize(), w:getMaxAmmo())
    end
end
return table.concat(o, "\n")
