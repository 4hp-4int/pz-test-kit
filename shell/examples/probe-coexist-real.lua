-- REAL-ECOSYSTEM coexistence: attach the actual mod magazine as a Clip
-- WeaponPart (as MarzGuns/Gunworks do), set the weapon's capacity from it
-- (as the mod does), then run the real VPS reapply with a clipSize affix.
-- Want: final maxAmmo == mag capacity + affix  (stack ON TOP, no clobber),
-- and that it SURVIVES a B42 field reset (Clip part persists).
local V, WD, SM = VorpallySauced, VorpallySauced.WeaponData, VorpallySauced.StatModifiers
local clipSfx, A
for i, s in ipairs(V.FirearmSuffixes) do
    if s.stat == "clipSize" then clipSfx, A = i, (s.value or 0) break end
end

local items = getScriptManager():getAllItems()
local R = {}
local function row(m) R[m] = R[m] or { n=0, apply=0, reset=0 }; return R[m] end
local samp = {}

for i = 0, items:size() - 1 do
    local sc = items:get(i)
    local mod = sc:getModuleName()
    if (mod == "MarzGuns" or mod == "Base") then
        local ft = mod .. "." .. sc:getName()
        local ok, w = pcall(instanceItem, ft)
        if ok and w and w.isRanged and w:isRanged() and WD.isValidFirearm(w)
           and w.getMagazineType and (w:getMagazineType() or "") ~= "" then
            local magType = w:getMagazineType()
            local okm, mag = pcall(instanceItem, magType)
            if okm and mag and mag.getMaxAmmo then
                local magCap = mag:getMaxAmmo() or 0
                -- attach the mag as the Clip WeaponPart (mirror the mod) + set
                -- the weapon's capacity from it (mirror CustomWeaponOnCreate)
                local attached = false
                if w.attachWeaponPart and instanceof(mag, "WeaponPart") then
                    pcall(function()
                        if w.canAttachWeaponPart == nil or w:canAttachWeaponPart(mag) then
                            w:attachWeaponPart(mag); attached = true
                        end
                    end)
                end
                if magCap > 0 then w:setMaxAmmo(magCap) end
                local clip = w.getWeaponPart and w:getWeaponPart("Clip")
                local clipMax = (clip and clip.getMaxAmmo and clip:getMaxAmmo()) or 0
                if attached and clipMax > 0 then
                    local g = row(mod); g.n = g.n + 1
                    local want = clipMax + A
                    local d = WD.getOrCreateModData(w); d.isFirearm = true
                    d.suffixId = clipSfx; d.dynamicCapacity = nil
                    WD.rt(d.weaponId).appliedClipBonus = 0

                    SM.reapplyUpgrades(w)                    -- VPS applies affix
                    local capA = w:getMaxAmmo()
                    if capA == want then g.apply = g.apply + 1 end

                    w:setMaxAmmo(8)                          -- B42 field reset
                    SM.reapplyUpgrades(w)                    -- reapply (Clip persists)
                    local capR = w:getMaxAmmo()
                    if capR == want then g.reset = g.reset + 1 end

                    if #samp < 12 then
                        samp[#samp+1] = string.format("%s magCap=%d want=%d apply=%s reset=%s",
                            ft, clipMax, want, tostring(capA), tostring(capR))
                    end
                end
            end
        end
    end
end

local o = { string.format("== REAL-ECOSYSTEM COEXISTENCE == affix +%s  SWMG=%s GGS=%s",
    tostring(A), tostring(V.Compat and V.Compat.SWMG), tostring(V.Compat and V.Compat.DynamicMagazines)) }
for m, g in pairs(R) do
    o[#o+1] = string.format("[%s] mag+Clip weapons=%d | affix-stacks-on-mag=%d/%d | survives-fieldreset=%d/%d",
        m, g.n, g.apply, g.n, g.reset, g.n)
end
o[#o+1] = "-- samples --"
for _, s in ipairs(samp) do o[#o+1] = "  " .. s end
return table.concat(o, "\n")
