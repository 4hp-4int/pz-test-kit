-- DYNAMIC MAG LIFECYCLE (mechanism-accurate). A real gun uses ONE mag
-- mechanism: Gunworks/MarzGuns attach a Clip WeaponPart; GGS swaps via
-- MagazineTypeNow ModData. Test each gun through its OWN mechanism across
-- multiple different-capacity mags + B42 field resets + N cycles, plus an
-- affixed-magazine restore leg. Invariant every step:
--    gunMaxAmmo == currentModMagCap + A    (stack, no clobber/drift)
--    appliedClipBonus == A                 (no double-count across cycles)
local V, WD, SM, MS = VorpallySauced, VorpallySauced.WeaponData,
                      VorpallySauced.StatModifiers, VorpallySauced.MagazineSync
local clipSfx, A
for i, s in ipairs(V.FirearmSuffixes) do
    if s.stat == "clipSize" then clipSfx, A = i, (s.value or 0) break end
end

-- WeaponPart magazines for the Clip-cycle (different capacities)
local CLIP_MAGS = {}
for _, mt in ipairs({ "MarzGuns.556x45Magazine30_STANAG", "MarzGuns.762x39Magazine30",
                      "MarzGuns.9x19Magazine20_MP5", "MarzGuns.3006Magazine20_BAR" }) do
    local ok, m = pcall(instanceItem, mt)
    if ok and m and instanceof(m, "WeaponPart") and (m:getMaxAmmo() or 0) > 0 then
        CLIP_MAGS[#CLIP_MAGS+1] = { t = mt, cap = m:getMaxAmmo() }
    end
end
-- REAL magazine items for the GGS-cycle: GGS writes MagazineTypeNow to an
-- actual mag fulltype; Reset resolves instanceItem(type):getMaxAmmo().
local GGS_MAGS = {}
for _, mt in ipairs({ "Base.9mmClip", "Base.556Clip", "Base.M14Clip",
                      "Base.ShotgunShellsBox", "Base.45Clip", "Base.762x39Mag30" }) do
    local ok, m = pcall(instanceItem, mt)
    if ok and m and m.getMaxAmmo and (m:getMaxAmmo() or 0) > 0 then
        GGS_MAGS[#GGS_MAGS+1] = { t = mt, cap = m:getMaxAmmo() }
    end
end

local fails = {}
local function fail(s) if #fails < 20 then fails[#fails+1] = s end end
local function appliedBonus(w)
    local d = WD.getModData(w); return d and d.weaponId and WD.rt(d.weaponId).appliedClipBonus
end

local function freshGun(ft)
    local ok, w = pcall(instanceItem, ft)
    if not (ok and w and w.isRanged and w:isRanged() and WD.isValidFirearm(w)) then return nil end
    local d = WD.getOrCreateModData(w); d.isFirearm = true
    d.suffixId = clipSfx; d.dynamicCapacity = nil
    WD.rt(d.weaponId).appliedClipBonus = 0
    return w
end

local results = {}

-- ---- Clip-part guns: cycle attached mag PARTS ----
for _, ft in ipairs({ "MarzGuns.AR15", "MarzGuns.AK47", "MarzGuns.M16A2", "MarzGuns.MP5" }) do
    local w = freshGun(ft)
    if w and #CLIP_MAGS > 0 then
        local steps, pass = 0, 0
        for cyc = 1, 2 do
            for _, mg in ipairs(CLIP_MAGS) do
                -- detach any existing Clip, attach the new mag part
                pcall(function()
                    local cur = w:getWeaponPart("Clip"); if cur then w:detachWeaponPart(cur) end
                end)
                local nm = instanceItem(mg.t)
                pcall(function()
                    if w.canAttachWeaponPart == nil or w:canAttachWeaponPart(nm) then w:attachWeaponPart(nm) end
                end)
                local clip = w:getWeaponPart("Clip")
                local cap = clip and clip:getMaxAmmo() or mg.cap
                w:setMaxAmmo(cap)
                SM.reapplyUpgrades(w)
                steps = steps + 1
                if w:getMaxAmmo() == cap + A and appliedBonus(w) == A then pass = pass + 1
                else fail(ft.." clip "..mg.t.." c"..cyc.." got "..w:getMaxAmmo().." want "..(cap+A)
                    .." ab="..tostring(appliedBonus(w))) end
                w:setMaxAmmo(7); SM.reapplyUpgrades(w)            -- B42 field reset
                steps = steps + 1
                if w:getMaxAmmo() == cap + A then pass = pass + 1
                else fail(ft.." clip-reset "..mg.t.." c"..cyc.." got "..w:getMaxAmmo().." want "..(cap+A)) end
            end
        end
        results[#results+1] = string.format("%-20s clip-cycle %d/%d", ft, pass, steps)
    end
end

-- ---- GGS-class guns: cycle MagazineTypeNow + capacity ----
for _, ft in ipairs({ "Base.AssaultRifle", "Base.Pistol", "Base.HuntingRifle",
                       "Base.Shotgun", "Base.pistol_shotgun" }) do
    local w = freshGun(ft)
    if w then
        local hasClip = w.getWeaponPart and w:getWeaponPart("Clip") ~= nil
        local steps, pass = 0, 0
        for cyc = 1, 2 do
            for _, mg in ipairs(GGS_MAGS) do
                w:getModData().MagazineTypeNow = mg.t
                w:setMaxAmmo(mg.cap)
                SM.reapplyUpgrades(w)
                steps = steps + 1
                -- if the gun has a real Clip part it (correctly) wins over a
                -- GGS swap; expected base is then the Clip part's cap.
                local cp = w.getWeaponPart and w:getWeaponPart("Clip")
                local base = (cp and cp:getMaxAmmo() and cp:getMaxAmmo() > 0) and cp:getMaxAmmo() or mg.cap
                if w:getMaxAmmo() == base + A and appliedBonus(w) == A then pass = pass + 1
                else fail(ft.." ggs "..mg.t.."("..mg.cap..") c"..cyc.." got "..w:getMaxAmmo().." want "..(base+A)
                    .." (hasClip="..tostring(hasClip)..")") end
                w:setMaxAmmo(7); SM.reapplyUpgrades(w)            -- B42 field reset
                steps = steps + 1
                if w:getMaxAmmo() == base + A then pass = pass + 1
                else fail(ft.." ggs-reset "..mg.t.." c"..cyc.." got "..w:getMaxAmmo().." want "..(base+A)) end
            end
        end
        results[#results+1] = string.format("%-20s ggs-cycle %d/%d", ft, pass, steps)
    end
end

-- ---- affixed-magazine restore leg ----
if MS and MS.applyBonusToMagazine and #CLIP_MAGS > 0 then
    local okm, am = pcall(instanceItem, CLIP_MAGS[1].t)
    if okm and am then
        local want = CLIP_MAGS[1].cap + 5
        MS.applyBonusToMagazine(am, 5, 0)
        local a1 = am:getMaxAmmo()
        am:setMaxAmmo(CLIP_MAGS[1].cap)                   -- B42 reset the mag item
        MS.restoreMagazineBonus(am)
        local a2 = am:getMaxAmmo()
        results[#results+1] = string.format("affixed-mag own +5: apply=%s restore=%s want=%d %s",
            tostring(a1), tostring(a2), want, (a1==want and a2==want) and "OK" or "FAIL")
        if not (a1==want and a2==want) then fail("affixed-mag bonus a1="..tostring(a1).." a2="..tostring(a2).." want "..want) end
    end
end

local o = { string.format("== MAG LIFECYCLE (mechanism-accurate) == affix +%s  clipMags=%d  SWMG=%s GGS=%s",
    tostring(A), #CLIP_MAGS, tostring(V.Compat and V.Compat.SWMG), tostring(V.Compat and V.Compat.DynamicMagazines)) }
for _, r in ipairs(results) do o[#o+1] = "  " .. r end
o[#o+1] = "-- failures (cap 20) --"
for _, f in ipairs(fails) do o[#o+1] = "  " .. f end
if #fails == 0 then o[#o+1] = "  NONE — lifecycle invariant held every step" end
return table.concat(o, "\n")
