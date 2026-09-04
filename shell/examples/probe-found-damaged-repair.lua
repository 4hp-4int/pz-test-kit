-- Found-damaged repair on the LIVE dedi VM.
--
-- Post-1.13.0 user report: a weapon picked up already damaged levels up and
-- only repairs to its found condition. Offline the core path is clean (three
-- regression tests); this probe runs the same scenario on the server VM and
-- adds the two things offline cannot: the dedi's aggressive ModData
-- pack/expand round-trip, and whatever a nil player does to the kill cycle.
local out = {}
local function line(s) out[#out + 1] = s end

local WD = VorpallySauced.WeaponData
local UM = VorpallySauced.UpgradeManager
local SM = VorpallySauced.StatModifiers

local w = instanceItem("Base.Axe")
if not w then return "FAIL: instanceItem returned nil" end
w:setCondition(3)
local scriptMax = w:getConditionMax()
line(("found: %d/%d"):format(w:getCondition(), scriptMax))

local data = WD.getOrCreateModData(w)
data.kills = data.prefixThreshold or 10

-- The real kill-cycle entry point, nil player exactly as a headless probe has.
local ok, err = pcall(UM.checkAndApplyUpgrades, w, nil, false, 0, data.kills, "probe")
line("checkAndApplyUpgrades(nil player) ok=" .. tostring(ok)
    .. (ok and "" or ("  err=" .. tostring(err))))

data = WD.getModData(w)
if not data.prefixId and ok then line("NOTE: no prefix applied") end
line(("after tier-up: cond=%d/%d savedCondition=%s prefixId=%s"):format(
    w:getCondition(), w:getConditionMax(),
    tostring(data.savedCondition), tostring(data.prefixId)))

local fullAfterUpgrade = (w:getCondition() == w:getConditionMax())

-- Dedi-flavour pack -> expand round trip, then a reapply like a resync does.
WD.compactModData(w)
data = WD.getModData(w)
line(("after pack/expand: savedCondition=%s"):format(tostring(data.savedCondition)))
pcall(SM.reapplyUpgrades, w)
line(("after reapply: cond=%d/%d"):format(w:getCondition(), w:getConditionMax()))

local verdict = fullAfterUpgrade and (w:getCondition() == w:getConditionMax())
line((verdict and ">>> PASS" or ">>> FAIL")
    .. " -- tier-up repair on the dedi "
    .. (verdict and "reaches full and survives pack+reapply"
                 or "did NOT hold full condition"))
return table.concat(out, "\n")
