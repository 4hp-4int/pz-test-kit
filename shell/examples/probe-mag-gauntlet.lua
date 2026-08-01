-- THE MAG GAUNTLET: every ranged firearm in Base (incl. GGS's ~332 injected)
-- + MarzGuns (GoM), run through the full VPS magazine lifecycle under live
-- SWMG+GGS. Per weapon:
--   invariant   : isDynamicCapacityWeapon == (getMagazineType() ~= "")
--   loose-ammo  : clipSize affix raises maxAmmo AND survives a B42 field
--                 reset + server reapply (full S1 lifecycle)
--   ceded (mag) : calculateClipSizeBonus==0, no checkClipCorruption
--                 false-positive, clipSize never rolled (20 tries)
local V, WD, SM, UM = VorpallySauced, VorpallySauced.WeaponData,
                      VorpallySauced.StatModifiers, VorpallySauced.UpgradeManager

local function isClip(a) return a and (a.stat == "clipSize" or (a.stats and a.stats.clipSize)) end
local clipSfx, clipVal
for i, s in ipairs(V.FirearmSuffixes) do if isClip(s) then clipSfx, clipVal = i, (s.value or 1) break end end

local sm, items = getScriptManager(), nil
items = sm:getAllItems()
local G = {}                       -- module -> stats
local function st(m)
    G[m] = G[m] or { n=0, mag=0, loose=0, invBad=0, looseOK=0, looseBad=0,
                      lifeOK=0, lifeBad=0, cedeBonusBad=0, cedeCorrupt=0, cedeRolled=0 }
    return G[m]
end
local fails = {}
local function note(s) if #fails < 20 then fails[#fails+1] = s end end

for i = 0, items:size() - 1 do
    local s = items:get(i)
    local mod = s:getModuleName()
    if mod == "Base" or mod == "MarzGuns" then
        local ft = mod .. "." .. s:getName()
        local ok, w = pcall(instanceItem, ft)
        if ok and w and w.isRanged and w:isRanged() and WD.isValidFirearm(w) then
            local g = st(mod); g.n = g.n + 1
            local mt = (w.getMagazineType and w:getMagazineType()) or ""
            local hasMag = mt ~= ""
            if hasMag then g.mag = g.mag + 1 else g.loose = g.loose + 1 end
            local d = WD.getOrCreateModData(w); d.isFirearm = true; d.dynamicCapacity = nil
            local ceded = V.isDynamicCapacityWeapon(w, d)

            if ceded ~= hasMag then
                g.invBad = g.invBad + 1
                note(ft .. " INVARIANT magType=" .. mt .. " ceded=" .. tostring(ceded))
            end

            if not ceded then
                -- loose-ammo: full S1 lifecycle
                local m0 = w:getMaxAmmo()
                d.suffixId = clipSfx
                SM.reapplyUpgrades(w)
                local m1 = w:getMaxAmmo()
                if m1 > m0 then g.looseOK = g.looseOK + 1
                else g.looseBad = g.looseBad + 1; note(ft .. " loose clipSize noop " .. m0 .. "->" .. m1) end
                -- B42 field reset -> server reapply must restore
                w:setMaxAmmo(m0)
                SM.reapplyUpgrades(w)
                if w:getMaxAmmo() == m1 then g.lifeOK = g.lifeOK + 1
                else g.lifeBad = g.lifeBad + 1
                     note(ft .. " lifecycle drift reset->" .. w:getMaxAmmo() .. " want " .. m1) end
            else
                -- ceded: must contribute nothing & not corrupt & never roll clip
                d.suffixId = clipSfx
                WD.rt(d.weaponId).appliedClipBonus = 0
                WD.rt(d.weaponId).needsStatRecalc = nil
                if WD.calculateClipSizeBonus(w) ~= 0 then
                    g.cedeBonusBad = g.cedeBonusBad + 1; note(ft .. " ceded calcBonus~=0") end
                WD.validateData(w)
                if WD.needsStatRecalc(w) then
                    g.cedeCorrupt = g.cedeCorrupt + 1; note(ft .. " ceded corruption false-pos") end
                for _ = 1, 20 do
                    if isClip(V.FirearmSuffixes[UM.selectRandomAffix("suffix", true, w)]) then
                        g.cedeRolled = g.cedeRolled + 1; note(ft .. " ceded rolled clipSize"); break
                    end
                end
            end
        end
    end
end

local o = { string.format("== MAG GAUNTLET == SWMG=%s clipSuffix=#%s(+%s)",
    tostring(V.Compat and V.Compat.SWMG), tostring(clipSfx), tostring(clipVal)) }
for m, g in pairs(G) do
    o[#o+1] = string.format(
        "[%s] firearms=%d mag=%d loose=%d | invariant-bad=%d | LOOSE applies=%d/%d lifecycle=%d/%d | CEDED bonus0-bad=%d corrupt-fp=%d clip-rolled=%d",
        m, g.n, g.mag, g.loose, g.invBad, g.looseOK, g.looseOK + g.looseBad,
        g.lifeOK, g.lifeOK + g.lifeBad, g.cedeBonusBad, g.cedeCorrupt, g.cedeRolled)
end
o[#o+1] = "-- failures (cap 20) --"
for _, f in ipairs(fails) do o[#o+1] = "  " .. f end
if #fails == 0 then o[#o+1] = "  NONE — full catalog clean" end
return table.concat(o, "\n")
