-- Does SWMG's own StatsFactory clobber a non-SWMG loose-ammo weapon's
-- maxAmmo? If NOT, VPS can safely own the nailgun's clipSize even under SWMG
-- (=> the blanket Compat.SWMG capacity cede is wrong; should be per-weapon).
local V, WD, SM = VorpallySauced, VorpallySauced.WeaponData, VorpallySauced.StatModifiers
local o = {}
local function L(s) o[#o + 1] = s end

local SF = nil
local ok, mod = pcall(require, "WeaponSystems/Utils/StatsFactory")
if ok and mod then SF = mod end
L("StatsFactory require: " .. tostring(SF ~= nil))

local w = instanceItem("nailgunsb42.NailGunRed")
if not w then return "FAIL: no nailgun" end
L(string.format("nailgun pre: maxAmmo=%s clip=%s magType=%q",
    tostring(w:getMaxAmmo()), tostring(w:getClipSize()),
    tostring(w.getMagazineType and w:getMagazineType() or "")))

-- VPS applies a +N clipSize affix (SWMG flag stays ON — real dedi state),
-- but force the per-weapon cede off to simulate the proposed fix.
local sv = V.Compat.SWMG
local sfxId, sfxVal
for i, s in ipairs(V.FirearmSuffixes) do
    if s.stat == "clipSize" then sfxId, sfxVal = i, s.value break end
end
local d = WD.getOrCreateModData(w); d.isFirearm = true; d.suffixId = sfxId; d.dynamicCapacity = nil
V.Compat.SWMG = false                       -- simulate per-weapon: nailgun NOT ceded
SM.reapplyUpgrades(w)
V.Compat.SWMG = sv                          -- restore real dedi state (SWMG on)
local afterVPS = w:getMaxAmmo()
L(string.format("after VPS clipSize +%s: maxAmmo=%s", tostring(sfxVal), tostring(afterVPS)))

-- Now run SWMG's OWN equip-time reapply on the nailgun. If SWMG owns
-- capacity for it, this resets maxAmmo back toward script default.
if SF and SF.ReapplyAllModifiers then
    local pcok, err = pcall(SF.ReapplyAllModifiers, w)
    L("SWMG ReapplyAllModifiers ran: " .. tostring(pcok) .. (pcok and "" or (" err=" .. tostring(err))))
    local afterSWMG = w:getMaxAmmo()
    L(string.format("after SWMG reapply: maxAmmo=%s  -> SWMG %s the nailgun's capacity",
        tostring(afterSWMG),
        (afterSWMG == afterVPS) and "DID NOT TOUCH (VPS can own it)"
                                 or "CLOBBERED (cede justified)"))
end
return table.concat(o, "\n")
