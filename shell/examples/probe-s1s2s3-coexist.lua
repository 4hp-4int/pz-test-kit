-- power00456 S1/S2/S3 re-confirmed under the COEXISTENCE contract, full
-- arsenal, live SWMG+GGS. Mechanism-accurate (Clip-part guns use the attached
-- mag; others use script/GGS), so expectations match the real source of truth.
--   S1  no "60->30 on fire": final == modBase + affix, and SURVIVES a B42
--       field reset (mod source persists). Loose-ammo: script + affix.
--   S2  VPS does not rewrite the mod's magazineType (mag system intact).
--   S3  scriptType conversion is non-destructive: kills/affixes/statOverrides
--       preserved, sticky set, no forced recalc.
local V, WD, SM = VorpallySauced, VorpallySauced.WeaponData, VorpallySauced.StatModifiers
local clipSfx, A
for i, s in ipairs(V.FirearmSuffixes) do
    if s.stat == "clipSize" then clipSfx, A = i, (s.value or 0) break end
end

local items = getScriptManager():getAllItems()
local R = {}
local function row(m) R[m]=R[m] or {n=0,s1=0,s1r=0,s2=0,s3=0}; return R[m] end
local fails = {}
local function note(s) if #fails < 20 then fails[#fails+1]=s end end

for i = 0, items:size() - 1 do
    local sc = items:get(i)
    local mod = sc:getModuleName()
    if mod == "Base" or mod == "MarzGuns" then
        local ft = mod .. "." .. sc:getName()
        local pr = instanceItem(ft)
        if pr and pr.isRanged and pr:isRanged() and WD.isValidFirearm(pr) then
            local g = row(mod); g.n = g.n + 1

            -- ---- S1/S2 ----
            local w = instanceItem(ft)
            local d = WD.getOrCreateModData(w); d.isFirearm = true
            d.suffixId = clipSfx; d.dynamicCapacity = nil
            WD.rt(d.weaponId).appliedClipBonus = 0
            local mt0 = (w.getMagazineType and w:getMagazineType()) or ""
            -- attach the real mag as a Clip part for mag weapons (mirror the mod)
            local base
            if mt0 ~= "" then
                local okm, mag = pcall(instanceItem, mt0)
                if okm and mag and instanceof(mag, "WeaponPart") and w.attachWeaponPart then
                    pcall(function() if w.canAttachWeaponPart==nil or w:canAttachWeaponPart(mag) then w:attachWeaponPart(mag) end end)
                end
                local clip = w.getWeaponPart and w:getWeaponPart("Clip")
                base = (clip and clip:getMaxAmmo() and clip:getMaxAmmo() > 0) and clip:getMaxAmmo()
                    or (okm and mag and mag:getMaxAmmo()) or w:getMaxAmmo()
                w:setMaxAmmo(base)
            else
                base = w:getMaxAmmo()
            end
            local want = base + A
            SM.reapplyUpgrades(w)
            local capA = w:getMaxAmmo()
            if capA == want then g.s1 = g.s1 + 1
            else note(ft.." S1 want "..want.." got "..tostring(capA)) end
            -- S1 field-reset survival
            w:setMaxAmmo(7); SM.reapplyUpgrades(w)
            if w:getMaxAmmo() == want then g.s1r = g.s1r + 1
            elseif capA == want then note(ft.." S1 reset drift -> "..tostring(w:getMaxAmmo())) end
            -- S2: VPS must not rewrite the mod's magazineType
            local mt1 = (w.getMagazineType and w:getMagazineType()) or ""
            if mt1 == mt0 then g.s2 = g.s2 + 1
            else note(ft.." S2 magType rewritten "..mt0.." -> "..mt1) end

            -- ---- S3: non-destructive scriptType conversion ----
            local w3 = instanceItem(ft)
            local d3 = WD.getOrCreateModData(w3); d3.isFirearm = true
            d3.kills = 222; d3.prefixId = 7; d3.suffixId = 5; d3.bondingId = 3
            d3.statOverrides = { conditionMax = 88 }
            d3.scriptType = "Base.__FAKE_OLD_VARIANT__"
            WD.rt(d3.weaponId)._validated = nil
            WD.validateData(w3)
            local a = WD.getModData(w3)
            if a and a.kills == 222 and a.prefixId == 7 and a.suffixId == 5
               and a.bondingId == 3 and a.statOverrides and a.statOverrides.conditionMax == 88
               and a.dynamicCapacity == true and not WD.needsStatRecalc(w3) then
                g.s3 = g.s3 + 1
            else
                note(string.format("%s S3 lost k=%s p=%s s=%s b=%s ov=%s dyn=%s recalc=%s",
                    ft, tostring(a and a.kills), tostring(a and a.prefixId),
                    tostring(a and a.suffixId), tostring(a and a.bondingId),
                    tostring(a and a.statOverrides and a.statOverrides.conditionMax),
                    tostring(a and a.dynamicCapacity), tostring(WD.needsStatRecalc(w3))))
            end
        end
    end
end

local o = { "== S1/S2/S3 UNDER COEXISTENCE == affix +"..tostring(A)
            .." SWMG="..tostring(V.Compat and V.Compat.SWMG)
            .." GGS="..tostring(V.Compat and V.Compat.DynamicMagazines) }
for m, g in pairs(R) do
    o[#o+1] = string.format("[%s] n=%d | S1 %d/%d (reset %d/%d) | S2 %d/%d | S3 %d/%d",
        m, g.n, g.s1, g.n, g.s1r, g.n, g.s2, g.n, g.s3, g.n)
end
o[#o+1] = "-- failures (cap 20) --"
for _, f in ipairs(fails) do o[#o+1] = "  "..f end
if #fails == 0 then o[#o+1] = "  NONE — power00456 S1/S2/S3 hold under coexistence" end
return table.concat(o, "\n")
