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

-- The Event object is exposed to Lua as just Add/Remove — no way to
-- introspect listener counts. Instead, do a dispatch round-trip: install
-- a temporary listener on a test event, fire it, confirm it ran. If the
-- event bus is functional at all, this flips the flag.
local _fired = false
local function testHandler() _fired = true end
Events.OnServerStarted.Add(testHandler)
Events.OnServerStarted.Remove(testHandler)  -- don't leak on real startup
-- Fire a one-off: triggerEvent runs every registered listener for a name.
-- We just want to prove the bus works end-to-end.
local _probeFired = false
local probeName = "VPSShellHealthProbe_" .. tostring(os.time and os.time() or 0)
LuaEventManager.AddEvent(probeName)
Events[probeName].Add(function() _probeFired = true end)
triggerEvent(probeName)
line("event bus dispatch:  " .. (_probeFired and "OK" or "FAIL"))

-- Runtime cache size. In v1.10 this is the accumulator for appliedClipBonus,
-- etc. — unbounded would suggest a leak.
local rtSize = 0
if VorpallySauced.WeaponData._runtime then
    for _ in pairs(VorpallySauced.WeaponData._runtime) do rtSize = rtSize + 1 end
end
line("WeaponData._runtime: " .. rtSize .. " entries")

return table.concat(lines, "\n")
