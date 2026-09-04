-- VPS live health check: module inventory, event listener counts, sandbox,
-- runtime cache sizes. Catches silent load failures without needing to trawl
-- the debug log.
--
-- Usage:
--   ./pz-shell eval -f examples/probe-vps-health.lua

local lines = {}
local function line(s) table.insert(lines, s) end

-- Version + top-level namespace.
line("VPS version:         " .. tostring(VorpallySauced and VorpallySauced.VERSION))

-- Expected namespaced modules. Omits hook-installing side-effect files
-- (ReloadSpeedHook, StaggerEffect) that don't export onto VorpallySauced.*
local expectedSharedModules = {
    "WeaponData", "StatModifiers", "MagazineSync", "CraftTransfer",
    "UpgradeManager", "WeaponTraits", "WeaponTraitEffects", "AffixRegistry",
    "Events", "EventBus", "API",
}
local missing = {}
for _, m in ipairs(expectedSharedModules) do
    if not VorpallySauced[m] then table.insert(missing, m) end
end
line("missing modules:     " .. (#missing == 0 and "none" or table.concat(missing, ", ")))

-- Key test hooks / fix markers.
line("Server ns exposed:   " .. tostring(VorpallySauced.Server ~= nil))
line("hasStaleFirearmStats:" .. tostring(VorpallySauced.WeaponData.hasStaleFirearmStats ~= nil))
line("calculateClipSizeBonus: " .. tostring(VorpallySauced.WeaponData.calculateClipSizeBonus ~= nil))

-- Affix counts — matches AffixRegistry tests.
line("firearm prefixes:    " .. tostring(#VorpallySauced.FirearmPrefixes))
line("firearm suffixes:    " .. tostring(#VorpallySauced.FirearmSuffixes))
line("melee prefixes:      " .. tostring(#VorpallySauced.Prefixes))
line("melee suffixes:      " .. tostring(#VorpallySauced.Suffixes))
line("bondings:            " .. tostring(#VorpallySauced.Bondings))

-- Sandbox state (the values the server is actually running with).
local sv = SandboxVars.VorpallySauced or {}
line("Sandbox.EnableMod:   " .. tostring(sv.EnableMod))
line("  PrefixKillsMin:    " .. tostring(sv.PrefixKillsMin))
line("  SuffixKillsMin:    " .. tostring(sv.SuffixKillsMin))
line("  BondingKillsMin:   " .. tostring(sv.BondingKillsMin))
line("  DisableMagazineSync: " .. tostring(sv.DisableMagazineSync))

-- triggerEvent dispatches on the NEXT game tick, not synchronously -- a
-- same-eval check always reads false (verified live 2026-09-04). What VPS
-- actually depends on is its own EventBus, which IS synchronous, so probe that.
local _fired = false
local _f = function() _fired = true end
local bus = VorpallySauced.Events and VorpallySauced.Events.OnUpgradeApplied
if bus then
    bus:addListener(_f)
    bus:fire(nil, nil, "healthprobe", 1, false)
    bus:removeListener(_f)
end
line("event bus dispatch:  " .. (_fired and "OK" or "FAIL"))

-- Runtime cache size. In v1.10 this is the accumulator for appliedClipBonus,
-- etc. — unbounded would suggest a leak.
local rtSize = 0
if VorpallySauced.WeaponData._runtime then
    for _ in pairs(VorpallySauced.WeaponData._runtime) do rtSize = rtSize + 1 end
end
line("WeaponData._runtime: " .. rtSize .. " entries")

return table.concat(lines, "\n")
