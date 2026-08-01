-- SWMG branch live check: under Compat.SWMG=true, isDynamicCapacityWeapon
-- must short-circuit true and VPS's clipSize affix must be inert.
local V = VorpallySauced
local WD = V.WeaponData
local SM = V.StatModifiers

local w = instanceItem("Base.Pistol")
local d = WD.getOrCreateModData(w)
local dyn = V.isDynamicCapacityWeapon(w, d)

local before = w:getMaxAmmo()
for i, s in ipairs(V.FirearmSuffixes) do
    if s.stat == "clipSize" then d.suffixId = i break end
end
SM.reapplyUpgrades(w)
SM.reapplyUpgrades(w)
local after = w:getMaxAmmo()

return string.format(
    "Compat.SWMG=%s isDynamicCapacity=%s clipSuffix=%s maxAmmo %s->%s %s",
    tostring(V.Compat.SWMG), tostring(dyn), tostring(d.suffixId),
    tostring(before), tostring(after),
    (before == after) and "PASS(no clobber)" or "FAIL(clobbered)")
