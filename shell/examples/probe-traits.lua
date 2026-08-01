-- WeaponTraits.computeCharacter over the kill-count ramp.
--
-- Lets you confirm that the live server's tier transitions match what the
-- sandbox is configured for. If you bump PrefixKillsMin / etc. at runtime
-- (PZ supports ini edits on restart), this probe will show the new stages
-- triggering at the new thresholds — fast config-correctness check.

local WT = VorpallySauced.WeaponTraits
if not WT or not WT.computeCharacter then return "FAIL: WeaponTraits.computeCharacter missing" end

-- Mock weapon shaped like what computeMood/computeCharacter read. We don't
-- need a real weapon — computeCharacter takes (data, weapon) and reads data
-- for kills/durabilityScale plus weapon for a couple of type checks.
local fakeWeapon = instanceItem("Base.HuntingKnife")
if not fakeWeapon then return "FAIL: couldn't spawn Base.HuntingKnife for probe" end

local lines = {}
local function L(s) table.insert(lines, s) end

L(string.format("%-8s %-14s %s", "kills", "primary", "modifier"))
L(string.rep("-", 40))

local killLadder = { 0, 5, 9, 10, 25, 29, 30, 75, 199, 200, 400, 800, 1500 }
local lastPrimary = nil
local transitions = {}
for _, kills in ipairs(killLadder) do
    local fakeData = {
        kills = kills,
        durabilityScale = 1.0,
        -- trait-computation fields kept at defaults — enough for primary tier.
        firstKillHour = nil, peakKillStreak = 0, nightKills = 0,
        currentHour = 0, currentHourKills = 0, windowStart = 0, windowKills = 0,
    }
    local char = WT.computeCharacter(fakeData, fakeWeapon)
    L(string.format("%-8d %-14s %s", kills, tostring(char.primary), tostring(char.modifier or "-")))
    if char.primary ~= lastPrimary then
        table.insert(transitions, string.format("%d->%s", kills, char.primary))
        lastPrimary = char.primary
    end
end

L("")
L("stage transitions observed:")
L("  " .. table.concat(transitions, "  "))

-- Compare to sandbox: prefix min is the "awakening" threshold, suffix min
-- is the next tier, bonding min is Blooded. If transitions don't align
-- with those, either the sandbox got out of sync or computeCharacter uses
-- hard-coded tiers (which it does — see PRIMARY_TIERS in WeaponTraits.lua).
local sv = SandboxVars.VorpallySauced or {}
L("")
L(string.format("sandbox thresholds: prefix>=%d suffix>=%d bonding>=%d",
    sv.PrefixKillsMin or -1, sv.SuffixKillsMin or -1, sv.BondingKillsMin or -1))

L("")
L("OK - stage progression dumped. Inspect transitions vs. sandbox expectations.")
return table.concat(lines, "\n")
