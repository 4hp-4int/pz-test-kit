-- Live: a ceded magazine weapon (GGS/SWMG) must never carry/roll a clipSize
-- affix and must not trip checkClipCorruption. Repros the pistol_shotgun report.
local V, WD, UM = VorpallySauced, VorpallySauced.WeaponData, VorpallySauced.UpgradeManager
local o = {}
local function L(s) o[#o + 1] = s end

local function isClip(a) return a and (a.stat == "clipSize" or (a.stats and a.stats.clipSize)) end
local clipSfx
for i, s in ipairs(V.FirearmSuffixes) do if isClip(s) then clipSfx = i break end end

-- Pick a real ceded magazine weapon: prefer pistol_shotgun, else first
-- magazine weapon that isDynamicCapacityWeapon says is ceded.
local sm = getScriptManager()
local items = sm:getAllItems()
local target, tw
for _, want in ipairs({ "pistol_shotgun" }) do
    for i = 0, items:size() - 1 do
        local s = items:get(i)
        if s:getName():lower() == want then
            local ft = s:getModuleName() .. "." .. s:getName()
            local ok, w = pcall(instanceItem, ft)
            if ok and w then target, tw = ft, w break end
        end
    end
end
if not tw then
    for i = 0, items:size() - 1 do
        local s = items:get(i)
        local ft = s:getModuleName() .. "." .. s:getName()
        local ok, w = pcall(instanceItem, ft)
        if ok and w and w.isRanged and w:isRanged() and WD.isValidFirearm(w) then
            local mt = w.getMagazineType and w:getMagazineType() or ""
            if mt ~= "" then target, tw = ft, w break end
        end
    end
end
if not tw then return "FAIL: no ceded magazine weapon found" end

local d = WD.getOrCreateModData(tw); d.isFirearm = true; d.dynamicCapacity = nil
local ceded = V.isDynamicCapacityWeapon(tw, d)
L(string.format("target=%s magType=%q ceded=%s", target,
    tostring(tw.getMagazineType and tw:getMagazineType() or ""), tostring(ceded)))

-- 1. roll exclusion: 200 selectRandomAffix("suffix") never clipSize
local rolledClip = 0
for _ = 1, 200 do
    local id = UM.selectRandomAffix("suffix", true, tw)
    if isClip(V.FirearmSuffixes[id]) then rolledClip = rolledClip + 1 end
end
L("clipSize suffix rolled over 200 tries: " .. rolledClip .. " (want 0)")

-- 2. stale clipSize affix forced on -> calculateClipSizeBonus 0, no corruption
d.suffixId = clipSfx
WD.rt(d.weaponId).appliedClipBonus = 0
WD.rt(d.weaponId).needsStatRecalc = nil
local bonus = WD.calculateClipSizeBonus(tw)
WD.validateData(tw)
local recalc = WD.needsStatRecalc(tw)
L(string.format("forced clipSize suffix #%s -> calculateClipSizeBonus=%s (want 0) | needsStatRecalc=%s (want false) | %s",
    tostring(clipSfx), tostring(bonus), tostring(recalc),
    (bonus == 0 and not recalc and rolledClip == 0) and "PASS" or "**FAIL**"))
return table.concat(o, "\n")
