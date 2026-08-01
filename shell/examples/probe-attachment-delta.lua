-- v1.10 attachment-delta integrity check.
--
-- v1.10.0 replaced stored originalStats with on-demand computation:
--   getOriginalStat(weapon, stat) = refWeapon[stat] + sum(attachmentPart[stat])
-- The refWeapon is a bare-script instanceItem (no attachments, full sharpness).
-- Attachment deltas come from WeaponPart.getMaxRange() etc.
--
-- Prior bug: originalStats contained post-affix values, so reset->reapply
-- compounded ("attachment inflation"). This probe proves the current impl
-- returns the UN-AFFIXED baseline regardless of current weapon mutation.

local WD = VorpallySauced.WeaponData
local SM = VorpallySauced.StatModifiers

local weapon = instanceItem("Base.Pistol")
if not weapon then return "FAIL: couldn't spawn Base.Pistol" end

-- Snapshot the untouched baseline via getOriginalStat.
local baseMaxDamage = WD.getOriginalStat(weapon, "maxDamage")
local baseMaxRange  = WD.getOriginalStat(weapon, "maxRange")
local baseHitChance = WD.getOriginalStat(weapon, "hitChance")

if not baseMaxDamage or not baseMaxRange then
    return "FAIL: getOriginalStat returned nil for a basic firearm"
end

-- Force the weapon's current fields to something clearly wrong. A correct
-- getOriginalStat reads from the reference cache + attachment deltas, so it
-- must IGNORE these mutations.
weapon:setMaxDamage(999)
weapon:setMaxRange(999)
weapon:setHitChance(1)

local afterMutBaseMaxDamage = WD.getOriginalStat(weapon, "maxDamage")
local afterMutBaseMaxRange  = WD.getOriginalStat(weapon, "maxRange")
local afterMutBaseHitChance = WD.getOriginalStat(weapon, "hitChance")

local lines = {}
local function L(s) table.insert(lines, s) end

L("Base.Pistol originalStat values:")
L(string.format("  pre-mutation:   maxDamage=%s  maxRange=%s  hitChance=%s",
    tostring(baseMaxDamage), tostring(baseMaxRange), tostring(baseHitChance)))
L(string.format("  post-setters:   maxDamage=%s  maxRange=%s  hitChance=%s",
    tostring(afterMutBaseMaxDamage), tostring(afterMutBaseMaxRange), tostring(afterMutBaseHitChance)))
L(string.format("  weapon fields now: maxDamage=%s  maxRange=%s  hitChance=%s",
    tostring(weapon:getMaxDamage()), tostring(weapon:getMaxRange()), tostring(weapon:getHitChance())))
L("")

local drift = (afterMutBaseMaxDamage ~= baseMaxDamage)
    or (afterMutBaseMaxRange ~= baseMaxRange)
    or (afterMutBaseHitChance ~= baseHitChance)

if drift then
    L("FAIL - getOriginalStat moved after setters. This is exactly the v1.10")
    L("       regression class: stored baselines getting polluted by current-state writes.")
    L("       Reset/reapply on this weapon would compound.")
else
    L("OK - getOriginalStat is stable under current-field mutation.")
    L("     Reference-weapon + attachment-delta computation is intact.")
end

-- Reference weapon cache inspection — sanity check that it exists and holds
-- the Pistol entry after our calls.
local refCache = WD._refWeaponCache
if refCache then
    local found, total = false, 0
    for k, _ in pairs(refCache) do
        total = total + 1
        if k == "Base.Pistol" then found = true end
    end
    L("")
    L(string.format("ref weapon cache: %d entries, Base.Pistol cached=%s",
        total, tostring(found)))
end

return table.concat(lines, "\n")
