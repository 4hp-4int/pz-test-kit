-- Live end-to-end revalidation of the v1.10.1 shotgun capacity fix.
--
-- Runs the same flow as the offline `magcap_server_cache_reapplies_stale_weapon`
-- test but against PZ's real HandWeapon objects in the live dedi Kahlua VM.
-- If this returns "OK", the fix works for real — not just in the mocks.
--
-- Usage:
--   ./pz-shell eval -f examples/probe-shotgun-stale-e2e.lua

local WD = VorpallySauced.WeaponData
local SM = VorpallySauced.StatModifiers
local ServerNS = VorpallySauced.Server

if not WD.hasStaleFirearmStats then return "FAIL: hasStaleFirearmStats not loaded on server" end
if not ServerNS or not ServerNS._ensureServerReapplied then
    return "FAIL: VorpallySauced.Server._ensureServerReapplied not exposed (test hook missing)"
end

-- Find "of Abundance". clipSize affix values are FRACTIONS of live capacity
-- now, not flat counts -- the probe used to hunt value == 12 and went stale
-- when the table changed underneath it (caught on the v1.13.0 release pass).
local suffixId, frac
for i, s in ipairs(VorpallySauced.FirearmSuffixes) do
    if s.stat == "clipSize" and s.value == 0.30 then suffixId, frac = i, s.value; break end
end
if not suffixId then return "FAIL: no 0.30 clipSize suffix found" end

-- Spawn + apply.
local shotgun = instanceItem("Base.Shotgun")
if not shotgun then return "FAIL: instanceItem(Base.Shotgun) returned nil" end

WD.getOrCreateModData(shotgun)
shotgun:getModData().VorpallySauced.suffixId = suffixId
SM.reapplyUpgrades(shotgun)

local origMax = WD.getOriginalStat(shotgun, "maxAmmo") or 0
-- Ask the mod's own arithmetic instead of re-deriving it: applyStat uses
-- clipSizePctBonus over the effective magazine base, and a probe that copies
-- the formula goes stale the moment the formula moves (this one did, twice).
local base = (WD.getEffectiveMagBase and WD.getEffectiveMagBase(shotgun)) or origMax
if not base or base <= 0 then base = origMax end
local bonus = WD.clipSizePctBonus(base, frac)
local expected = origMax + bonus
local afterApply = shotgun:getMaxAmmo()
if afterApply ~= expected then
    return string.format("FAIL: after apply, maxAmmo=%d expected=%d", afterApply, expected)
end

-- Prime the server reapply cache (mirrors the onKill path running once).
ServerNS._clearReapplyCache(shotgun:getID())
local firstReapply = ServerNS._ensureServerReapplied(shotgun)
if not firstReapply then return "FAIL: first ensureServerReapplied didn't reapply" end

-- Simulate PZ chunk-reload: Java fields snap back to script defaults.
shotgun:setMaxAmmo(origMax)
shotgun:setClipSize(origMax)
local stale = WD.hasStaleFirearmStats(shotgun)
local afterReset = shotgun:getMaxAmmo()
if afterReset ~= origMax then
    return string.format("FAIL: after reset, maxAmmo=%d expected=%d", afterReset, origMax)
end
if not stale then return "FAIL: hasStaleFirearmStats didn't flag stale weapon" end

-- Second call: cache was primed, stats are stale, must reapply anyway.
local secondReapply = ServerNS._ensureServerReapplied(shotgun)
local afterSecond = shotgun:getMaxAmmo()

if not secondReapply then
    return "FAIL: second ensureServerReapplied skipped (stale cache not detected)"
end
if afterSecond ~= expected then
    return string.format("FAIL: after stale-reapply, maxAmmo=%d expected=%d", afterSecond, expected)
end

return string.format(
    "OK — shotgun stale-cache fix is LIVE. orig=%d applied=%d reset=%d recovered=%d (bonus=+%d)",
    origMax, afterApply, afterReset, afterSecond, bonus)
