local V,WD,SM = VorpallySauced, VorpallySauced.WeaponData, VorpallySauced.StatModifiers
-- This dedi runs SWMG (MarzGuns) → Compat.SWMG cedes clipSize for ALL
-- firearms by design. Force it off to isolate VPS's real clipSize logic
-- (reproduces a plain non-SWMG server, which is where the user report is).
local sv, dv = V.Compat.SWMG, V.Compat.DynamicMagazines
V.Compat.SWMG, V.Compat.DynamicMagazines = false, false
local o = {}
local sfxId, sfxVal
for i, s in ipairs(V.FirearmSuffixes) do
    if s.stat == "clipSize" then sfxId, sfxVal = i, s.value break end
end
for _, n in ipairs({ "Base.Revolver", "Base.Shotgun", "Base.Pistol" }) do
    local w = instanceItem(n)
    if w then
        local m0, c0 = w:getMaxAmmo(), w:getClipSize()
        local d = WD.getOrCreateModData(w); d.isFirearm = true; d.suffixId = sfxId
        d.dynamicCapacity = nil
        SM.reapplyUpgrades(w)
        local m1, c1 = w:getMaxAmmo(), w:getClipSize()
        w:setMaxAmmo(m0); w:setClipSize(c0)            -- simulate B42 field reset
        local stale = WD.hasStaleFirearmStats(w)
        SM.reapplyUpgrades(w)                           -- server-reapply
        local m2 = w:getMaxAmmo()
        o[#o+1] = string.format(
            "%s reload=%s | pre max=%s clip=%s | +%s => max=%s clip=%s | reset+reapply max=%s | stale=%s | loadable raised=%s",
            n, tostring(w:getWeaponReloadType()), tostring(m0), tostring(c0),
            tostring(sfxVal), tostring(m1), tostring(c1), tostring(m2),
            tostring(stale), tostring(m2 > m0))
    end
end
V.Compat.SWMG, V.Compat.DynamicMagazines = sv, dv
return table.concat(o, "\n")
