-- Live-VM probe: suppressor soundRadius preservation (v1.10.10 fix).
-- Exercises the REAL PZ HandWeapon API + reapplyUpgrades end-to-end, which the
-- offline Kahlua harness only approximates. Verifies that a suppressor's
-- soundRadius reduction survives a VPS reapply instead of snapping back to the
-- unsuppressed script base.

local VPS = VorpallySauced
local WeaponData = VPS.WeaponData
local SM = VPS.StatModifiers
local out = {}
local function line(s) table.insert(out, s) end

-- Find a firearm suffix that multiplies soundRadius by 0.70 (of Silence).
local soundSuffixId, soundMult
for i, a in ipairs(VPS.FirearmSuffixes or {}) do
    if a.stat == "soundRadius" and a.value and math.abs(a.value - 0.70) < 0.001 then
        soundSuffixId, soundMult = i, a.value; break
    end
end

-- Find a firearm prefix that does NOT touch sound/noise.
local nonSoundPrefixId
for i, a in ipairs(VPS.FirearmPrefixes or {}) do
    local touches = (a.stat == "soundRadius" or a.stat == "noiseRange")
    if a.stats and (a.stats.soundRadius or a.stats.noiseRange) then touches = true end
    if not touches then nonSoundPrefixId = i; break end
end

line("soundSuffixId=" .. tostring(soundSuffixId) .. " (mult " .. tostring(soundMult) ..
     "), nonSoundPrefixId=" .. tostring(nonSoundPrefixId))

local weapon = instanceItem("Base.Pistol")
if not weapon then return "FAIL: could not instanceItem Base.Pistol" end
weapon:setCondition(weapon:getConditionMax())

local baseSound = WeaponData.getOriginalStat(weapon, "soundRadius") or weapon:getSoundRadius() or 0
line("reference (unsuppressed) soundRadius = " .. tostring(baseSound))
if baseSound <= 10 then return table.concat(out, "\n") .. "\nSKIP: base soundRadius too low" end

-- Stamp VPS data + a non-sound affix, then simulate a suppressor (absolute low).
local data = WeaponData.getOrCreateModData(weapon)
data.kills = 500; data.isFirearm = true
data.prefixId = nonSoundPrefixId; data.prefixThreshold = 0
local suppressed = math.max(1, math.floor(baseSound * 0.2))
weapon:setSoundRadius(suppressed)
line("simulated suppressor: soundRadius set to " .. tostring(suppressed))

-- TEST 1 (the reported bug): unrelated affix reapply must NOT revert it.
SM.reapplyUpgrades(weapon)
local afterUnrelated = weapon:getSoundRadius()
local pass1 = (afterUnrelated == suppressed)
line(string.format("TEST1 unrelated-upgrade: soundRadius=%d (want %d) -> %s",
    afterUnrelated, suppressed, pass1 and "PASS" or "FAIL"))

-- TEST 2: add the sound suffix; reduction stacks on the suppressed base.
data.suffixId = soundSuffixId; data.suffixThreshold = 0
SM.reapplyUpgrades(weapon)
local afterSound = weapon:getSoundRadius()
local expected = math.max(1, math.floor(suppressed * soundMult + 0.5))
local pass2 = (afterSound == expected)
line(string.format("TEST2 relative-stack: soundRadius=%d (want %d = %d*%.2f) -> %s",
    afterSound, expected, suppressed, soundMult, pass2 and "PASS" or "FAIL"))

-- TEST 3: idempotent across repeated reapply.
for _ = 1, 4 do SM.reapplyUpgrades(weapon) end
local afterIdem = weapon:getSoundRadius()
local pass3 = (afterIdem == expected)
line(string.format("TEST3 idempotent: soundRadius=%d (want %d) -> %s",
    afterIdem, expected, pass3 and "PASS" or "FAIL"))

-- TEST 4: persisted multiplier present in ModData.
local persisted = data.appliedSoundRadiusMult
local pass4 = persisted and math.abs(persisted - soundMult) < 0.001
line(string.format("TEST4 persisted-mult: appliedSoundRadiusMult=%s -> %s",
    tostring(persisted), pass4 and "PASS" or "FAIL"))

line((pass1 and pass2 and pass3 and pass4) and "ALL PASS" or "SOME FAILED")
return table.concat(out, "\n")
