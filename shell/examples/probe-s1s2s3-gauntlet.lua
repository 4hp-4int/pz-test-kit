-- power00456 regression gauntlet across the FULL arsenal (Base incl. GGS +
-- MarzGuns), live under SWMG+GGS. Per weapon:
--   S1  drum 60->30 on fire: ceded weapon's mod-set capacity is NOT clobbered
--       by VPS reapply; loose-ammo clipSize applies AND survives field reset
--   S2  upgrade reverts mag: VPS must NOT rewrite magazineType / force
--       clipSize/maxAmmo on a ceded weapon (mod stays free to swap drums)
--   S3  drum swap blank-slates: scriptType conversion is non-destructive —
--       kills/affixes/statOverrides preserved, sticky set, no forced recalc
local V, WD, SM = VorpallySauced, VorpallySauced.WeaponData, VorpallySauced.StatModifiers
local clipSfx
for i, s in ipairs(V.FirearmSuffixes) do
    if s.stat == "clipSize" or (s.stats and s.stats.clipSize) then clipSfx = i break end
end

local items = getScriptManager():getAllItems()
local R = {}
local function row(m) R[m] = R[m] or { n=0, s1=0,s1b=0, s2=0,s2b=0, s3=0,s3b=0 }; return R[m] end
local fails = {}
local function note(s) if #fails < 20 then fails[#fails+1] = s end end

for i = 0, items:size() - 1 do
    local sc = items:get(i)
    local mod = sc:getModuleName()
    if mod == "Base" or mod == "MarzGuns" then
        local ft = mod .. "." .. sc:getName()
        local ok = pcall(instanceItem, ft)
        if ok then
            local probe = instanceItem(ft)
            if probe and probe.isRanged and probe:isRanged() and WD.isValidFirearm(probe) then
                local g = row(mod); g.n = g.n + 1

                -- ---- S1 / S2 (capacity + mag-system integrity) ----
                local w = instanceItem(ft)
                local d = WD.getOrCreateModData(w); d.isFirearm = true; d.dynamicCapacity = nil
                -- Ground-truth class (NOT the code's own verdict) so this is a
                -- behavioral before/after test: loose-ammo MUST get a working
                -- clipSize affix; a mod-mag weapon's drum MUST be left alone.
                local mt0 = (w.getMagazineType and w:getMagazineType()) or ""
                if mt0 ~= "" then
                    -- mod set a drum; VPS must leave capacity + mag system alone
                    local drum = (w:getMaxAmmo() or 0) + 40
                    w:setMaxAmmo(drum)
                    local c0 = w:getClipSize()
                    d.suffixId = clipSfx
                    SM.reapplyUpgrades(w); SM.reapplyUpgrades(w)   -- equip + fire
                    if w:getMaxAmmo() == drum then g.s1 = g.s1 + 1
                    else g.s1b = g.s1b + 1; note(ft.." S1 drum clobbered "..drum.."->"..tostring(w:getMaxAmmo())) end
                    local mt1 = (w.getMagazineType and w:getMagazineType()) or ""
                    if mt1 == mt0 and w:getClipSize() == c0 then g.s2 = g.s2 + 1
                    else g.s2b = g.s2b + 1; note(ft.." S2 VPS rewrote mag/clip mt "..mt0.."->"..mt1) end
                else
                    -- loose-ammo: clipSize applies AND survives B42 field reset
                    local m0 = w:getMaxAmmo()
                    d.suffixId = clipSfx
                    SM.reapplyUpgrades(w)
                    local m1 = w:getMaxAmmo()
                    w:setMaxAmmo(m0); SM.reapplyUpgrades(w)        -- reset + fire-reapply
                    if m1 > m0 and w:getMaxAmmo() == m1 then g.s1 = g.s1 + 1
                    else g.s1b = g.s1b + 1; note(ft.." S1 loose "..m0.."->"..m1.."->"..tostring(w:getMaxAmmo())) end
                    g.s2 = g.s2 + 1   -- no mag system to break
                end

                -- ---- S3 (non-destructive scriptType conversion) ----
                local w3 = instanceItem(ft)
                local d3 = WD.getOrCreateModData(w3)
                d3.isFirearm = true
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
                    g.s3b = g.s3b + 1
                    note(string.format("%s S3 lost k=%s p=%s s=%s b=%s ov=%s dyn=%s recalc=%s",
                        ft, tostring(a and a.kills), tostring(a and a.prefixId),
                        tostring(a and a.suffixId), tostring(a and a.bondingId),
                        tostring(a and a.statOverrides and a.statOverrides.conditionMax),
                        tostring(a and a.dynamicCapacity), tostring(WD.needsStatRecalc(w3))))
                end
            end
        end
    end
end

local o = { "== power00456 S1/S2/S3 GAUNTLET == SWMG="..tostring(V.Compat and V.Compat.SWMG) }
for m, g in pairs(R) do
    o[#o+1] = string.format("[%s] n=%d | S1 %d/%d | S2 %d/%d | S3 %d/%d",
        m, g.n, g.s1, g.s1+g.s1b, g.s2, g.s2+g.s2b, g.s3, g.s3+g.s3b)
end
o[#o+1] = "-- failures (cap 20) --"
for _, f in ipairs(fails) do o[#o+1] = "  "..f end
if #fails == 0 then o[#o+1] = "  NONE — full arsenal clean on S1/S2/S3" end
return table.concat(o, "\n")
