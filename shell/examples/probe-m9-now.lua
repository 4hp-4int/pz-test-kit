-- Capture EVERY M9 + every magazine in player inventory, ALL ModData keys
-- (not just VorpallySauced), so we can see exactly what state the held
-- "fake blooded" gun is in vs server's view.

local lines = {}
local function add(s) table.insert(lines, s) end

local player = getPlayer()
if not player then
    local online = getOnlinePlayers()
    if online and online:size() > 0 then player = online:get(0) end
end
if not player then return "FAIL: no player" end

add("=== M9 NOW probe ===")
add("player:           " .. tostring(player:getUsername()))
add("primary in hand:  " .. tostring(player:getPrimaryHandItem() and player:getPrimaryHandItem():getID() or "nil"))
add("secondary:        " .. tostring(player:getSecondaryHandItem() and player:getSecondaryHandItem():getID() or "nil"))
add("server timestamp: " .. tostring(getTimestampMs()))
add("")

local function dumpAllKeys(md, indent)
    indent = indent or "    "
    local count = 0
    local keys = {}
    for k in pairs(md) do table.insert(keys, k); count = count + 1 end
    table.sort(keys)
    add(indent .. "(" .. count .. " keys total)")
    for _, k in ipairs(keys) do
        local v = md[k]
        if type(v) == "table" then
            add(indent .. k .. " = (table)")
            local subkeys = {}
            for k2 in pairs(v) do table.insert(subkeys, tostring(k2)) end
            table.sort(subkeys)
            for _, k2 in ipairs(subkeys) do
                local v2 = v[k2]
                add(indent .. "  " .. tostring(k2) .. " = " .. tostring(v2))
            end
        else
            add(indent .. k .. " = " .. tostring(v))
        end
    end
end

local primary = player:getPrimaryHandItem()

local m9s = {}
local mags = {}
for i = 0, player:getInventory():getItems():size() - 1 do
    local it = player:getInventory():getItems():get(i)
    local ft = it:getFullType() or ""
    if ft == "Base.Pistol" then table.insert(m9s, it)
    elseif ft == "Base.9mmClip" then table.insert(mags, it)
    end
end

for i, gun in ipairs(m9s) do
    local marker = (primary and gun:getID() == primary:getID()) and " <-- HELD" or ""
    add("===== M9 [" .. i .. "] id=" .. gun:getID() .. marker .. " =====")
    add("    runtime name:        " .. tostring(gun:getName()))
    add("    runtime displayName: " .. tostring(gun:getDisplayName()))
    add("    isContainsClip:      " .. tostring(gun:isContainsClip()))
    add("    currentAmmo:         " .. tostring(gun:getCurrentAmmoCount()))
    add("    clipSize/maxAmmo:    " .. tostring(gun:getClipSize()) .. "/" .. tostring(gun:getMaxAmmo()))
    add("    --- ALL ModData keys ---")
    dumpAllKeys(gun:getModData())
    add("")
end

add("===== Loose magazines (" .. #mags .. ") =====")
for i, mag in ipairs(mags) do
    add("[mag " .. i .. "] id=" .. mag:getID())
    add("    runtime name: " .. tostring(mag:getName()))
    add("    maxAmmo:      " .. tostring(mag:getMaxAmmo()))
    add("    --- ALL ModData keys ---")
    dumpAllKeys(mag:getModData())
    add("")
end

return table.concat(lines, "\n")
