-- Magazine bonus lifecycle round-trip: a clipSize affix on a gun should:
--   1. transfer to an external magazine on eject
--   2. survive a PZ save/load stat-reset (ModData persists, maxAmmo resets)
--
-- We can't easily trigger ISEjectMagazine.unloadAmmo without a timed-action
-- context, but we CAN exercise the underlying MagazineSync helpers directly
-- — they're what the hook calls after instanceItem'ing the new mag.

local MS = VorpallySauced.MagazineSync
if not MS then return "FAIL: MagazineSync not loaded" end

local mag = instanceItem("Base.9mmClip")
if not mag then return "FAIL: couldn't spawn Base.9mmClip" end

local lines = {}
local function L(s) table.insert(lines, s) end

-- Baseline: fresh magazine has script maxAmmo, no VPS tracking.
local scriptMax = mag:getMaxAmmo() or 0
L(string.format("fresh 9mmClip: maxAmmo=%d", scriptMax))
L(string.format("  VS tracking present: %s",
    tostring(mag:getModData()["VorpallySauced_appliedClipBonus"] or "none")))

-- Step 1: apply a +5 bonus (as if the weapon had 'of Storage' suffix).
local applied = MS.applyBonusToMagazine(mag, 5, 12345)
L(string.format("applyBonusToMagazine(+5): ok=%s, maxAmmo=%d",
    tostring(applied), mag:getMaxAmmo()))
if mag:getMaxAmmo() ~= scriptMax + 5 then
    return "FAIL: apply didn't land — expected " .. (scriptMax + 5)
end

-- Inspect the ModData keys that the restore relies on.
local md = mag:getModData()
L(string.format("  VorpallySauced_originalMaxAmmo:  %s",
    tostring(md["VorpallySauced_originalMaxAmmo"])))
L(string.format("  VorpallySauced_appliedClipBonus: %s",
    tostring(md["VorpallySauced_appliedClipBonus"])))
L(string.format("  VorpallySauced_sourceWeaponId:   %s",
    tostring(md["VorpallySauced_sourceWeaponId"])))

-- Step 2: simulate PZ deserialisation wiping the Java field. ModData persists.
mag:setMaxAmmo(scriptMax)
L(string.format("after sim PZ reset: maxAmmo=%d (ModData still has bonus=%s)",
    mag:getMaxAmmo(), tostring(md["VorpallySauced_appliedClipBonus"])))

-- Step 3: the JIT restore path the tooltip/eject hook uses.
local restored = MS.restoreMagazineBonus(mag)
L(string.format("restoreMagazineBonus: restored=%s, maxAmmo=%d",
    tostring(restored), mag:getMaxAmmo()))
if mag:getMaxAmmo() ~= scriptMax + 5 then
    return "FAIL: restore didn't recover — expected " .. (scriptMax + 5)
end

-- Step 4: helper readers that tooltips + other callers use.
L(string.format("getMagazineBonus:     %d", MS.getMagazineBonus(mag)))
L(string.format("getOriginalMaxAmmo:   %s", tostring(MS.getOriginalMaxAmmo(mag))))

L("")
L(string.format("OK - apply/reset/restore round-trip passes (%d -> %d -> %d -> %d)",
    scriptMax, scriptMax + 5, scriptMax, mag:getMaxAmmo()))
return table.concat(lines, "\n")
