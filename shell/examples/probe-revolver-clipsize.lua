-- Repro: does a VPS clipSize affix actually raise loadable capacity on a
-- revolver-class (loose-ammo, no MagazineType) weapon — the nailgun's class?
-- Also exercises the B42 field-reset + server-reapply path.
local V  = VorpallySauced
local WD = V.WeaponData
local SM = V.StatModifiers
local out = {}
local function L(s) out[#out+1] = s end

local function pick()
    for _, n in ipairs({"Base.Revolver","Base.Revolver_Long","Base.Pistol"}) do
        local ok, w = pcall(instanceItem, n)
        if ok and w then return n, w end
    end
end

local name, w = pick()
if not w then return "FAIL: no revolver/pistol instanceItem" end

local rt = w.getWeaponReloadType and w:getWeaponReloadType() or "?"
local scrMax = w:getScriptItem():getMaxAmmo()
L(string.format("%s reloadType=%s scriptMaxAmmo=%s clipSize=%s maxAmmo=%s",
    name, tostring(rt), tostring(scrMax), tostring(w:getClipSize()), tostring(w:getMaxAmmo())))

-- Apply a clipSize firearm suffix (+N) via the real VPS path.
local d = WD.getOrCreateModData(w)
d.isFirearm = true
local sfxId, sfxVal
for i, s in ipairs(V.FirearmSuffixes) do
    if s.stat == "clipSize" then sfxId, sfxVal = i, s.value break end
end
if not sfxId then return "FAIL: no clipSize FirearmSuffix" end
d.suffixId = sfxId
SM.reapplyUpgrades(w)
L(string.format("after apply (+%s): clipSize=%s maxAmmo=%s  expected maxAmmo=%s",
    tostring(sfxVal), tostring(w:getClipSize()), tostring(w:getMaxAmmo()), tostring(scrMax + sfxVal)))

-- Simulate B42 mid-session field reset (deserialize → script defaults).
w:setMaxAmmo(scrMax)
w:setClipSize(w:getScriptItem():getClipSize())
L(string.format("after PZ field reset: maxAmmo=%s (stale)", tostring(w:getMaxAmmo())))
L("hasStaleFirearmStats=" .. tostring(WD.hasStaleFirearmStats(w))
  .. " calculateClipSizeBonus=" .. tostring(WD.calculateClipSizeBonus(w))
  .. " getOriginalStat(maxAmmo)=" .. tostring(WD.getOriginalStat(w, "maxAmmo")))

-- Server-side reapply (what ServerLogic.ensureServerReapplied does on a stale hit).
SM.reapplyUpgrades(w)
local fixedMax = w:getMaxAmmo()
L(string.format("after server reapply: maxAmmo=%s %s",
    tostring(fixedMax),
    (fixedMax == scrMax + sfxVal) and "PASS(loadable raised)" or "FAIL(still capped at script)"))

-- Prove the reload cap: vanilla ISReloadWeaponAction loads while
-- getCurrentAmmoCount() < getMaxAmmo(). Simulate.
w:setCurrentAmmoCount(scrMax)
L(string.format("at script-max ammo (%s): can still load? %s (currentAmmo %s < maxAmmo %s)",
    tostring(scrMax), tostring(w:getCurrentAmmoCount() < w:getMaxAmmo()),
    tostring(w:getCurrentAmmoCount()), tostring(w:getMaxAmmo())))

return table.concat(out, "\n")
