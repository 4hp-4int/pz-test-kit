-- Deep diag for the M9 magazine-tooltip leak.
-- Captures EVERYTHING that could influence the tooltip: gun ModData (raw +
-- expanded), runtime name fields, all VorpallySauced_* keys, inserted
-- magazine state, and a simulated tooltip-cache build.

local WD = VorpallySauced and VorpallySauced.WeaponData
if not WD then return "FAIL: WeaponData not loaded" end

local player = getPlayer()
if not player then
    local online = getOnlinePlayers()
    if online and online:size() > 0 then player = online:get(0) end
end
if not player then return "FAIL: no player" end

local lines = { "=== M9 DEEP probe ===" }
local function add(s) table.insert(lines, s) end

local inv = player:getInventory()
local items = inv:getItems()

local function dumpAllVPSKeys(md, indent)
    indent = indent or "    "
    local keys = {}
    for k, v in pairs(md) do
        if string.find(tostring(k), "VorpallySauced", 1, true) then
            table.insert(keys, k)
        end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local v = md[k]
        if type(v) == "table" then
            add(indent .. k .. " = (table)")
            for k2, v2 in pairs(v) do
                if type(v2) == "table" then
                    add(indent .. "  " .. tostring(k2) .. " = (table)")
                else
                    add(indent .. "  " .. tostring(k2) .. " = " .. tostring(v2))
                end
            end
        else
            add(indent .. k .. " = " .. tostring(v))
        end
    end
end

local function deepDumpGun(label, gun)
    add("")
    add(label .. " " .. gun:getFullType() .. " (id=" .. gun:getID() .. ")")
    add("    runtime getName():       " .. tostring(gun:getName()))
    add("    runtime getDisplayName():" .. tostring(gun:getDisplayName()))
    local script = gun:getScriptItem()
    add("    script DisplayName:      " .. tostring(script and script:getDisplayName()))
    -- Stats
    add("    clipSize:                " .. tostring(gun:getClipSize()))
    add("    maxAmmo:                 " .. tostring(gun:getMaxAmmo()))
    add("    minDamage:               " .. tostring(gun:getMinDamage()))
    add("    maxDamage:               " .. tostring(gun:getMaxDamage()))
    add("    hitChance:               " .. tostring(gun:getHitChance()))
    add("    recoilDelay:             " .. tostring(gun:getRecoilDelay()))
    -- Magazine state
    add("    isContainsClip:          " .. tostring(gun:isContainsClip()))
    add("    currentAmmoCount:        " .. tostring(gun:getCurrentAmmoCount()))
    add("    magazineType:            " .. tostring(gun:getMagazineType()))
    -- ALL VorpallySauced_* keys on ModData (top-level scalars + the subtable)
    add("    --- ModData VorpallySauced_* keys ---")
    dumpAllVPSKeys(gun:getModData())
    -- Expanded VPS subtable
    local vps = WD.getModData(gun)
    if vps then
        add("    --- WeaponData.getModData expanded ---")
        for k, v in pairs(vps) do
            if type(v) ~= "table" then
                add("    VPS." .. k .. " = " .. tostring(v))
            else
                add("    VPS." .. k .. " = (table)")
            end
        end
    else
        add("    --- WeaponData.getModData returned nil (untracked) ---")
    end
end

local m9s = {}
local mags = {}
for i = 0, items:size() - 1 do
    local it = items:get(i)
    if it:getFullType() == "Base.Pistol" then
        table.insert(m9s, it)
    elseif it:getFullType() == "Base.9mmClip" then
        table.insert(mags, it)
    end
end

add("M9 count: " .. #m9s .. ", loose 9mmClip count: " .. #mags)

for i, gun in ipairs(m9s) do
    deepDumpGun("[M9 " .. i .. "]", gun)
end

add("")
add("--- Loose magazines ---")
for i, mag in ipairs(mags) do
    add("[mag " .. i .. "] id=" .. mag:getID() .. " name=" .. tostring(mag:getName()) ..
        " maxAmmo=" .. tostring(mag:getMaxAmmo()))
    dumpAllVPSKeys(mag:getModData(), "    ")
end

return table.concat(lines, "\n")
