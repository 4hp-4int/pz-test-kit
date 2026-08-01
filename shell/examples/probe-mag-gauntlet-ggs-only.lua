-- GGS-ONLY scenario (GaelGunStore installed, NO Guns of Marz / SWMG).
-- Force Compat.SWMG=false (keep DynamicMagazines=true) and re-run the full
-- magazine gauntlet across the Base catalog (GGS-injected + vanilla).
-- Expectation: identical correctness — mag weapons ceded via the GGS
-- (DynamicMagazines) path, loose-ammo weapons keep working clipSize.
local V, WD, SM, UM = VorpallySauced, VorpallySauced.WeaponData,
                      VorpallySauced.StatModifiers, VorpallySauced.UpgradeManager
local function isClip(a) return a and (a.stat == "clipSize" or (a.stats and a.stats.clipSize)) end
local clipSfx
for i, s in ipairs(V.FirearmSuffixes) do if isClip(s) then clipSfx = i break end end

-- Simulate GGS-only: SWMG absent, GGS present.
local saveSWMG, saveDyn = V.Compat.SWMG, V.Compat.DynamicMagazines
V.Compat.SWMG = false
V.Compat.DynamicMagazines = true

local items = getScriptManager():getAllItems()
local n, mag, loose, invBad, looseOK, looseBad, lifeOK, lifeBad,
      cedeBonusBad, cedeCorrupt, cedeRolled = 0,0,0,0,0,0,0,0,0,0,0
local fails = {}
local function note(s) if #fails < 15 then fails[#fails+1] = s end end

for i = 0, items:size() - 1 do
    local s = items:get(i)
    if s:getModuleName() == "Base" then
        local ft = "Base." .. s:getName()
        local ok, w = pcall(instanceItem, ft)
        if ok and w and w.isRanged and w:isRanged() and WD.isValidFirearm(w) then
            n = n + 1
            local mt = (w.getMagazineType and w:getMagazineType()) or ""
            local hasMag = mt ~= ""
            if hasMag then mag = mag + 1 else loose = loose + 1 end
            local d = WD.getOrCreateModData(w); d.isFirearm = true; d.dynamicCapacity = nil
            local ceded = V.isDynamicCapacityWeapon(w, d)
            if ceded ~= hasMag then invBad = invBad + 1
                note(ft .. " INVARIANT magType=" .. mt .. " ceded=" .. tostring(ceded)) end
            if not ceded then
                local m0 = w:getMaxAmmo()
                d.suffixId = clipSfx; SM.reapplyUpgrades(w)
                local m1 = w:getMaxAmmo()
                if m1 > m0 then looseOK = looseOK + 1
                else looseBad = looseBad + 1; note(ft .. " loose noop " .. m0 .. "->" .. m1) end
                w:setMaxAmmo(m0); SM.reapplyUpgrades(w)
                if w:getMaxAmmo() == m1 then lifeOK = lifeOK + 1
                else lifeBad = lifeBad + 1; note(ft .. " lifecycle drift") end
            else
                d.suffixId = clipSfx
                WD.rt(d.weaponId).appliedClipBonus = 0
                WD.rt(d.weaponId).needsStatRecalc = nil
                if WD.calculateClipSizeBonus(w) ~= 0 then cedeBonusBad = cedeBonusBad + 1; note(ft.." calcBonus~=0") end
                WD.validateData(w)
                if WD.needsStatRecalc(w) then cedeCorrupt = cedeCorrupt + 1; note(ft.." corrupt-fp") end
                for _ = 1, 20 do
                    if isClip(V.FirearmSuffixes[UM.selectRandomAffix("suffix", true, w)]) then
                        cedeRolled = cedeRolled + 1; note(ft.." rolled clipSize"); break end
                end
            end
        end
    end
end

V.Compat.SWMG, V.Compat.DynamicMagazines = saveSWMG, saveDyn

local o = {
    string.format("== GGS-ONLY (SWMG forced off, DynamicMagazines on) ==  clipSuffix=#%s", tostring(clipSfx)),
    string.format("[Base/GGS] firearms=%d mag=%d loose=%d | invariant-bad=%d | LOOSE applies=%d/%d lifecycle=%d/%d | CEDED bonus0-bad=%d corrupt-fp=%d clip-rolled=%d",
        n, mag, loose, invBad, looseOK, looseOK + looseBad, lifeOK, lifeOK + lifeBad,
        cedeBonusBad, cedeCorrupt, cedeRolled),
    "-- failures --",
}
for _, f in ipairs(fails) do o[#o+1] = "  " .. f end
if #fails == 0 then o[#o+1] = "  NONE — GGS-only catalog clean" end
return table.concat(o, "\n")
