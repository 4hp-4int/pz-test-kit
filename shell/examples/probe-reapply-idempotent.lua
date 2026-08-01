-- Full apply/reset round-trip against a real melee weapon.
--
-- Mirrors `reset_reapply_idempotent` from the offline suite: apply a stack
-- of affixes, capture the resulting stats, then call reapplyUpgrades N more
-- times and assert the stats didn't drift. Drift = double-application or
-- stale-accumulator bug.
--
-- Live bonus: uses a REAL Base.Axe with PZ's real HandWeapon class, full
-- sharpness, real conditionMax math. The offline version uses a mock axe
-- that matches vanilla script defaults but doesn't exercise the Java-side
-- sharpness calculation.

local WD = VorpallySauced.WeaponData
local SM = VorpallySauced.StatModifiers

local axe = instanceItem("Base.Axe")
if not axe then return "FAIL: couldn't spawn Base.Axe" end

-- Full condition + sharpness so getters return RAW values (PZ's getters
-- multiply by sharpness; we want to compare apples to apples).
if axe.setCondition and axe.getConditionMax then axe:setCondition(axe:getConditionMax()) end
if axe.setHeadCondition and axe.getHeadConditionMax then axe:setHeadCondition(axe:getHeadConditionMax()) end
if axe.applyMaxSharpness then axe:applyMaxSharpness() end

-- Seed ModData with a prefix + suffix. Any IDs that exist in the registry
-- will work; we pick 1/1 for simplicity.
WD.getOrCreateModData(axe)
local d = axe:getModData().VorpallySauced
d.prefixId = 1
d.suffixId = 1

-- Snapshot post-first-apply.
SM.reapplyUpgrades(axe)
local first = {
    maxDamage      = axe:getMaxDamage(),
    minDamage      = axe:getMinDamage(),
    critChance     = axe:getCriticalChance(),
    critDmgMult    = axe:getCriticalDamageMultiplier(),
    conditionMax   = axe:getConditionMax(),
    condLowerCh    = axe:getConditionLowerChance(),
}

-- Hammer reapplyUpgrades a bunch. If the codebase has a hidden "each apply
-- stacks on top of previous" bug, at least one stat will drift.
for i = 1, 7 do SM.reapplyUpgrades(axe) end

local last = {
    maxDamage      = axe:getMaxDamage(),
    minDamage      = axe:getMinDamage(),
    critChance     = axe:getCriticalChance(),
    critDmgMult    = axe:getCriticalDamageMultiplier(),
    conditionMax   = axe:getConditionMax(),
    condLowerCh    = axe:getConditionLowerChance(),
}

local lines = {}
local function L(s) table.insert(lines, s) end
L(string.format("Base.Axe with prefix=%d suffix=%d", d.prefixId, d.suffixId))
L("")
L(string.format("%-14s %-14s %-14s %s", "stat", "after apply#1", "after apply#8", "drift"))
L(string.rep("-", 55))

local drifts = 0
for k, v in pairs(first) do
    local diff = math.abs((last[k] or 0) - v)
    local drifted = diff > 0.001
    if drifted then drifts = drifts + 1 end
    L(string.format("%-14s %-14.4f %-14.4f %s",
        k, v, last[k] or 0, drifted and ("DRIFT +" .. diff) or "-"))
end

L("")
if drifts == 0 then
    L("OK - 8 reapplies produced identical stats; no double-apply / accumulator drift.")
else
    L("FAIL - " .. drifts .. " stat(s) drifted across 8 reapplies.")
end
return table.concat(lines, "\n")
