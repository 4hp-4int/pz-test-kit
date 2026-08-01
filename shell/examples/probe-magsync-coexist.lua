-- Does MagazineSync double-count under coexistence? On an SWMG/MarzGuns server
-- MagazineSync is ENABLED (gating only excludes GGS). Core.applyStat still
-- stamps pendingMagazineBonus on isContainsClip even though coexistence now
-- also applies the gun affix to maxAmmo. Chain:
--   gunA (+A) inserted clip -> coexistence gunA = clipCap+A, pendingBonus=A
--   eject  -> MagazineSync stamps ejMag = magScript + A   (mag now "affixed")
--   insert ejMag into gunB (+A) -> Clip part = ejMag (maxAmmo magScript+A)
--   reapply gunB -> Reset bases off clip(magScript+A) + gunB affix +A = ??
-- Correct: NOT magScript + 2A.
local V, WD, SM, MS = VorpallySauced, VorpallySauced.WeaponData,
                      VorpallySauced.StatModifiers, VorpallySauced.MagazineSync
local clipSfx, A
for i, s in ipairs(V.FirearmSuffixes) do
    if s.stat == "clipSize" then clipSfx, A = i, (s.value or 0) break end
end

local function gun(ft)
    local ok, w = pcall(instanceItem, ft)
    if not (ok and w and w.isRanged and w:isRanged() and WD.isValidFirearm(w)) then return nil end
    local d = WD.getOrCreateModData(w); d.isFirearm = true
    d.suffixId = clipSfx; d.dynamicCapacity = nil
    WD.rt(d.weaponId).appliedClipBonus = 0
    return w
end

local items = getScriptManager():getAllItems()
local out, dbl, clean, total = {}, 0, 0, 0
for i = 0, items:size() - 1 do
    local sc = items:get(i)
    if sc:getModuleName() == "MarzGuns" and total < 14 then
        local ft = "MarzGuns." .. sc:getName()
        local probe = instanceItem(ft)
        if probe and probe.isRanged and probe:isRanged() and WD.isValidFirearm(probe)
           and probe.getMagazineType and (probe:getMagazineType() or "") ~= "" then
            local magType = probe:getMagazineType()
            local okm, m0 = pcall(instanceItem, magType)
            local magScript = (okm and m0 and m0.getMaxAmmo and m0:getMaxAmmo()) or 0
            if magScript > 0 and instanceof(m0, "WeaponPart") then
                total = total + 1
                -- gunA: affix + inserted clip -> coexistence
                local gA = gun(ft)
                local m1 = instanceItem(magType)
                pcall(function() if gA.canAttachWeaponPart==nil or gA:canAttachWeaponPart(m1) then gA:attachWeaponPart(m1) end end)
                gA:setMaxAmmo(magScript)
                if gA.setContainsClip then pcall(gA.setContainsClip, gA, true) end
                SM.reapplyUpgrades(gA)
                local pend = MS.getPendingMagazineBonus(gA) or 0
                local capA = gA:getMaxAmmo()

                -- eject: model the PATCHED unloadAmmo hook — it early-returns
                -- for a dynamic-capacity gun BEFORE resolving any bonus, so
                -- the ejected mag stays plain (no VPS stamp).
                local ejMag = instanceItem(magType)
                local fb = 0
                if not (V.isDynamicCapacityWeapon and V.isDynamicCapacityWeapon(gA)) then
                    fb = (MS.getInsertedMagazineBonus(gA) or 0)
                    if fb == 0 then fb = pend end
                    if fb == 0 then fb = WD.calculateClipSizeBonus(gA) or 0 end
                end
                if fb > 0 then MS.applyBonusToMagazine(ejMag, fb, gA:getID()) end
                local ejCap = ejMag:getMaxAmmo()

                -- insert ejMag into gunB (also affixed) -> capture + attach
                local gB = gun(ft)
                local mb = ejMag:getModData()
                MS.setInsertedMagazineBonus(gB,
                    mb.VorpallySauced_appliedClipBonus or fb,
                    mb.VorpallySauced_suffixId, mb.VorpallySauced_bondingId)
                pcall(function() if gB.canAttachWeaponPart==nil or gB:canAttachWeaponPart(ejMag) then gB:attachWeaponPart(ejMag) end end)
                gB:setMaxAmmo(ejCap)
                if gB.setContainsClip then pcall(gB.setContainsClip, gB, true) end
                SM.reapplyUpgrades(gB)
                local capB = gB:getMaxAmmo()

                local isDouble = capB >= magScript + 2*A
                if isDouble then dbl = dbl + 1 else clean = clean + 1 end
                if #out < 12 then out[#out+1] = string.format(
                    "%s magScript=%d gunA=%d pend=%d ejMag=%d gunB=%d %s",
                    sc:getName(), magScript, capA, pend, ejCap, capB,
                    isDouble and ("**DOUBLE (>= "..(magScript+2*A)..")**") or "ok") end
            end
        end
    end
end

local o = { string.format("== MAGSYNC x COEXISTENCE == affix +%d  MagSyncEnabledGate(SWMG-server)=%s  this-dedi GGS=%s",
    A, tostring(not (V.Compat and V.Compat.DynamicMagazines)),
    tostring(V.Compat and V.Compat.DynamicMagazines)) }
o[#o+1] = string.format("MarzGuns tested=%d | DOUBLE-COUNT=%d | clean=%d", total, dbl, clean)
for _, l in ipairs(out) do o[#o+1] = "  " .. l end
return table.concat(o, "\n")
