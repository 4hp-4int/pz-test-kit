-- Live verification of the per-weapon SWMG capacity cede (v1.10.5 fix).
-- Real SWMG dedi (Compat.SWMG=true, MarzGuns + nailgun loaded).
local V, WD, SM = VorpallySauced, VorpallySauced.WeaponData, VorpallySauced.StatModifiers
local o = {}
local function L(s) o[#o + 1] = s end
L("Compat.SWMG=" .. tostring(V.Compat and V.Compat.SWMG))

local sfxId, sfxVal
for i, s in ipairs(V.FirearmSuffixes) do
    if s.stat == "clipSize" then sfxId, sfxVal = i, s.value break end
end

local function check(label, fulltype, expectCede)
    local w = instanceItem(fulltype)
    if not w then L(label .. ": instanceItem FAIL (" .. fulltype .. ")") return end
    local mt = w.getMagazineType and w:getMagazineType() or ""
    local d = WD.getOrCreateModData(w); d.isFirearm = true; d.dynamicCapacity = nil
    local ceded = V.isDynamicCapacityWeapon(w, d)
    local m0 = w:getMaxAmmo()
    d.suffixId = sfxId
    SM.reapplyUpgrades(w)
    local m1 = w:getMaxAmmo()
    local verdict = (ceded == expectCede) and "OK" or "**WRONG**"
    L(string.format("%s [%s] magType=%q ceded=%s (want %s) %s | maxAmmo %s->%s clipSize+%s %s",
        label, fulltype, tostring(mt), tostring(ceded), tostring(expectCede), verdict,
        tostring(m0), tostring(m1), tostring(sfxVal),
        ceded and "(affix inert, expected)"
              or ((m1 > m0) and "(affix APPLIED — fixed!)" or "(**affix failed**)")))
end

-- Loose-ammo, no magazine: must NOT be ceded under SWMG; clipSize must apply.
check("nailgun ", "nailgunsb42.NailGunRed", false)
check("revolver", "Base.Revolver",          false)
check("pumpSG  ", "Base.Shotgun",           false)
-- Detachable-magazine: still ceded under SWMG (framework owns capacity).
check("pistol  ", "Base.Pistol",            true)

-- A real MarzGuns weapon (detachable mag) should still be ceded.
local sm = getScriptManager()
local items = sm:getAllItems()
for i = 0, items:size() - 1 do
    local it = items:get(i)
    if it:getModuleName() == "MarzGuns" then
        local fn = it:getModuleName() .. "." .. it:getName()
        local ok, w = pcall(instanceItem, fn)
        if ok and w and w.isRanged and w:isRanged() then
            local d = WD.getOrCreateModData(w); d.isFirearm = true; d.dynamicCapacity = nil
            L(string.format("marzGuns[%s] magType=%q ceded=%s (want true)",
                fn, tostring(w.getMagazineType and w:getMagazineType() or ""),
                tostring(V.isDynamicCapacityWeapon(w, d))))
            break
        end
    end
end
return table.concat(o, "\n")
