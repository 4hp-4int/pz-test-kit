-- DEDI INVENTORY STATE PROBE — diagnostic for VPS data integrity on the
-- server side. This probe runs against the DEDICATED SERVER's view of a
-- player's inventory.
--
-- IMPORTANT: server-side weapon `runtime name` will ALWAYS be the script
-- default ("Katana", "Baseball Bat", ...) — the dedi never calls
-- StatModifiers.reapplyUpgrades because UpgradeNotifications.onGameStart
-- is a CLIENT-only flow (per CLAUDE.md note: OnGameStart doesn't fire on
-- dedicated servers). The affixed name lives in the CLIENT's process; the
-- "NAME REVERTED" line below is the EXPECTED server-side state, not a bug.
--
-- What this probe IS useful for:
--   - Confirming ModData expansion works on the dedi (VPS.prefixId etc. populated)
--   - Auditing which weapons in the player's save have affixes
--   - Diagnosing missing-VPS-data issues on dedi (compaction problems)
--
-- The original purpose (catching the v1.10.1 client-side onGameStart bug
-- where the inventory loop read raw modData.VorpallySauced.prefixId on a
-- packed weapon and silently bailed) is now covered by:
--   - PackedFormatTests.lua (Tier 1 + 2)
--   - probe-packed-fixes.lua (Tier 3 dedi)
-- Dedi context: getPlayer() returns nil. Use online players list.
local player = getPlayer()
if not player then
    local online = getOnlinePlayers()
    if online and online:size() > 0 then player = online:get(0) end
end
if not player then return "FAIL: no player (no one connected to dedi?)" end

local WD = VorpallySauced and VorpallySauced.WeaponData
if not WD then return "FAIL: WeaponData not loaded" end

local lines = { "=== name-revert probe ===" }
local function add(s) table.insert(lines, s) end

local inv = player:getInventory()
local items = inv:getItems()
add("inventory item count: " .. tostring(items:size()))

local weaponsFound = 0
for i = 0, items:size() - 1 do
    local item = items:get(i)
    if WD.isValidAnyWeapon(item) then
        -- Use getModData (expands packed format) — raw md.VorpallySauced may
        -- be the packed string form { _ = "..." } where prefixId/suffixId/etc
        -- are not direct fields.
        local vps = WD.getModData(item)
        local hasAffix = vps and (vps.prefixId or vps.suffixId or vps.bondingId)
        if vps then
            weaponsFound = weaponsFound + 1
            local script = item:getScriptItem()
            local scriptName = script and script.getDisplayName and script:getDisplayName() or "?"
            local runtimeName = item:getName()
            add("")
            add("[" .. weaponsFound .. "] " .. tostring(item:getFullType()))
            add("    runtime name:        " .. tostring(runtimeName))
            add("    script DisplayName:  " .. tostring(scriptName))
            add("    VPS.originalName:    " .. tostring(vps.originalName))
            add("    VPS.prefixId:        " .. tostring(vps.prefixId))
            add("    VPS.suffixId:        " .. tostring(vps.suffixId))
            add("    VPS.bondingId:       " .. tostring(vps.bondingId))
            add("    hasAffix:            " .. tostring(hasAffix))
            add("    nameMatchesScript:   " .. tostring(runtimeName == scriptName))
            if hasAffix and runtimeName == scriptName then
                add("    >>> NAME REVERTED: data is here but reapply did not land")
            elseif hasAffix and runtimeName ~= scriptName then
                add("    >>> name correctly reflects affixes")
            elseif not hasAffix then
                add("    (untracked weapon — no VPS data, name should be script default)")
            end
        end
    end
end

if weaponsFound == 0 then
    add("(no VPS-tracked weapons in main inventory; check backpacks)")
end

return table.concat(lines, "\n")
