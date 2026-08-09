-- Grant kills to the equipped weapon and run the upgrade check, exactly the way
-- ServerLogic's `debugAddKills` handler does (ServerLogic.lua:487-503) — minus
-- the canUseDebugCommands() gate, which pz-shell already outranks.
--
-- Edit KILLS below, then:
--   ./pz-shell eval -f examples/probe-vps-grant-kills.lua
-- or drop it into Zomboid/Lua/pz-shell/queue.txt for a local SP client.

local KILLS = 500

local out = {}
local function line(s) table.insert(out, s) end

local WeaponData    = VorpallySauced and VorpallySauced.WeaponData
local UpgradeManager = VorpallySauced and VorpallySauced.UpgradeManager
if not (WeaponData and UpgradeManager) then
    return "VorpallySauced not loaded (WeaponData/UpgradeManager missing)"
end

-- Resolve the subject. getSpecificPlayer(0) is client-side and returns nil on a
-- dedicated server, so prefer the online list there. Pass USERNAME to pick a
-- specific player when more than one is connected.
local USERNAME = nil

local player
local online = getOnlinePlayers()
if online and online:size() > 0 then
    for i = 0, online:size() - 1 do
        local u = online:get(i)
        if not USERNAME or u:getUsername() == USERNAME then player = u; break end
    end
end
if not player and getSpecificPlayer then player = getSpecificPlayer(0) end
if not player then
    return "no player found (online=" .. tostring(online and online:size() or 0) .. ")"
end

local weapon = player:getPrimaryHandItem()
if not weapon then return "nothing in the primary hand — equip the weapon first" end
if not WeaponData.isValidAnyWeapon(weapon) then
    return "not a VPS-eligible weapon: " .. tostring(weapon:getFullType())
end

local data      = WeaponData.getOrCreateModData(weapon)
local isFirearm = WeaponData.isValidFirearm(weapon)
local oldKills  = data.kills or 0

line("weapon:      " .. tostring(weapon:getName()) .. "  (" .. tostring(weapon:getFullType()) .. ")")
line("firearm:     " .. tostring(isFirearm))
line("kills before: " .. tostring(oldKills))

for _ = 1, KILLS do
    WeaponData.incrementKills(weapon)
end

data = WeaponData.getModData(weapon)
local newKills = data.kills
line("kills after:  " .. tostring(newKills))

-- Thresholds + affix rolls + stat application + sync all hang off this.
local ok, err = pcall(UpgradeManager.checkAndApplyUpgrades,
    weapon, player, isFirearm, oldKills, newKills, "debug_addkills")
line("upgrade pass: " .. (ok and "ran" or ("THREW: " .. tostring(err))))

data = WeaponData.getModData(weapon)
line("prefixId:    " .. tostring(data.prefixId))
line("suffixId:    " .. tostring(data.suffixId))
line("bondingId:   " .. tostring(data.bondingId))
line("name now:    " .. tostring(weapon:getName()))

return table.concat(out, "\n")
