-- Live verification of the dynamic-capacity / variant-conversion fix.
-- Real server-side HandWeapon objects on the dedi (isServer()==true).
-- Covers: Rain's-class scriptType conversion (S3 non-destructive) and the
-- S1 60->30-on-fire repro (capacity stable across reapply when dynamic).

local V  = VorpallySauced
local WD = V.WeaponData
local SM = V.StatModifiers
local out = {}
local function line(s) out[#out+1] = s end

-- ----- 1. Predicate is live -----
line("isDynamicCapacityWeapon present: " .. tostring(V.isDynamicCapacityWeapon ~= nil))

-- ----- 2. Rain's-class conversion is non-destructive (S3) -----
local w = instanceItem("Base.Shotgun")
local d = WD.getOrCreateModData(w)
d.isFirearm = true
d.kills = 142
d.prefixId, d.suffixId, d.bondingId = 2, 3, 1
d.statOverrides = { conditionMax = 77 }
d.scriptType = "Base.ShotgunPretendOldVariant"   -- simulate setScriptItem swap
WD.rt(d.weaponId)._validated = nil
WD.validateData(w)
local a = WD.getModData(w)
line(string.format(
  "S3 conversion: kills=%s(want142) prefix=%s suffix=%s bonding=%s override=%s dynCap=%s recalc=%s",
  tostring(a.kills), tostring(a.prefixId), tostring(a.suffixId), tostring(a.bondingId),
  tostring(a.statOverrides and a.statOverrides.conditionMax),
  tostring(a.dynamicCapacity), tostring(WD.needsStatRecalc(w))))

-- ----- 3. S1: capacity stable across reapply when dynamic-capacity -----
local g = instanceItem("Base.Shotgun")
local gd = WD.getOrCreateModData(g)
gd.isFirearm = true
gd.dynamicCapacity = true                 -- mod owns capacity
gd.suffixId = nil
for i, sfx in ipairs(V.FirearmSuffixes) do
  if sfx.stat == "clipSize" then gd.suffixId = i; break end
end
g:setMaxAmmo(60)                          -- 60-round drum set by the mod
SM.reapplyUpgrades(g)                      -- equip
SM.reapplyUpgrades(g)                      -- fire-triggered reapply
line(string.format("S1 drum: clipSizeSuffix=%s maxAmmo_after_2x_reapply=%d (want 60)",
  tostring(gd.suffixId), g:getMaxAmmo()))

-- ----- 4. Bare capacity excess is NOT auto-flagged (corruption boundary) -----
-- Only meaningful when SWMG/GGS is absent: those compat flags globally cede
-- capacity for ALL firearms by design (mirrors foreignOwnsRecoil), so a
-- vanilla weapon is correctly dynamic-capacity on an SWMG server. The
-- boundary invariant is asserted offline (dynmag_predicate_ignores_bare_
-- capacity_excess) where no SWMG is loaded.
local v = instanceItem("Base.Pistol")
local vd = WD.getOrCreateModData(v)
local refMax = WD.getOriginalStat(v, "maxAmmo") or 0
v:setMaxAmmo(refMax + 110)                 -- looks like corruption, not a mod
local swmg = V.Compat and V.Compat.SWMG
local got = V.isDynamicCapacityWeapon(v, vd)
local want = swmg and true or false
line(string.format("bare excess: refMax=%d Compat.SWMG=%s isDynCap=%s (want %s) %s",
  refMax, tostring(swmg), tostring(got), tostring(want),
  (got == want) and "PASS" or "FAIL"))

return table.concat(out, "\n")
