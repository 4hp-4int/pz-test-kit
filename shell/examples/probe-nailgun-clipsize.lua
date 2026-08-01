local V,WD,SM = VorpallySauced, VorpallySauced.WeaponData, VorpallySauced.StatModifiers
local o = {}
local function L(s) o[#o+1] = s end

local NG
for _, n in ipairs({ "nailgunsb42.NailGunRed", "nailgunsb42.NailGunBlue", "nailgunsb42.NailGunYellow" }) do
    local ok, w = pcall(instanceItem, n)
    if ok and w then NG = n break end
end
if not NG then return "FAIL: cannot instanceItem a nailgun" end

local sfxId, sfxVal
for i, s in ipairs(V.FirearmSuffixes) do
    if s.stat == "clipSize" then sfxId, sfxVal = i, s.value break end
end

local function run(label, swmgOn)
    local sv, dv = V.Compat.SWMG, V.Compat.DynamicMagazines
    V.Compat.SWMG = swmgOn and true or false
    V.Compat.DynamicMagazines = false
    local w = instanceItem(NG)
    local m0, c0 = w:getMaxAmmo(), w:getClipSize()
    local isFA = WD.isValidFirearm(w)
    local dyn = V.isDynamicCapacityWeapon(w, nil)
    local d = WD.getOrCreateModData(w); d.isFirearm = true; d.suffixId = sfxId; d.dynamicCapacity = nil
    SM.reapplyUpgrades(w)
    local m1, c1 = w:getMaxAmmo(), w:getClipSize()
    w:setMaxAmmo(m0); w:setClipSize(c0)                 -- B42 field reset
    local stale = WD.hasStaleFirearmStats(w)
    SM.reapplyUpgrades(w)                                -- server reapply
    local m2 = w:getMaxAmmo()
    V.Compat.SWMG, V.Compat.DynamicMagazines = sv, dv
    L(string.format("[%s] %s reload=%s isValidFirearm=%s isDynCap=%s | pre max=%s clip=%s | +%s => max=%s clip=%s | reset+reapply max=%s | stale=%s | loadable raised=%s",
        label, NG, tostring(w:getWeaponReloadType()), tostring(isFA), tostring(dyn),
        tostring(m0), tostring(c0), tostring(sfxVal), tostring(m1), tostring(c1),
        tostring(m2), tostring(stale), tostring(m2 > m0)))
end

run("SWMG OFF (normal server)", false)
run("SWMG ON  (this dedi real state)", true)
L("calculateClipSizeBonus=" .. tostring(WD.calculateClipSizeBonus(instanceItem(NG)))
  .. " getOriginalStat(maxAmmo)=" .. tostring(WD.getOriginalStat(instanceItem(NG), "maxAmmo"))
  .. " getOriginalStat(clipSize)=" .. tostring(WD.getOriginalStat(instanceItem(NG), "clipSize")))
return table.concat(o, "\n")
