-- Diagnostic for the user-reported M9 + magazine tooltip leak:
-- A Blooded M9 had its magazine ejected. A non-VPS M9 received the affixed
-- magazine. The non-VPS M9's tooltip then displayed Blooded-style content.
--
-- Walks the connected player's inventory and reports:
--   - every firearm/M9 by ID, with VPS data state
--   - every magazine in inventory, with VPS-related ModData (suffix names,
--     bonding names, applied-bonus tracking)
--   - the magazine currently inside each firearm (containsClip view)

local WD = VorpallySauced and VorpallySauced.WeaponData
if not WD then return "FAIL: WeaponData not loaded" end

local player = getPlayer()
if not player then
    local online = getOnlinePlayers()
    if online and online:size() > 0 then player = online:get(0) end
end
if not player then return "FAIL: no player" end

local lines = { "=== M9 + magazine tooltip leak probe ===" }
local function add(s) table.insert(lines, s) end

local inv = player:getInventory()
local items = inv:getItems()
add("inventory item count: " .. tostring(items:size()))

local function dumpVPS(label, item)
    add("  " .. label .. ": " .. tostring(item:getFullType()) ..
        " (id=" .. tostring(item:getID()) .. ")")
    add("    runtime name:        " .. tostring(item:getName()))
    local md = item:getModData()
    local vps = WD.getModData(item)
    add("    raw VPS present:     " .. tostring(md.VorpallySauced ~= nil))
    add("    raw VPS packed?:     " .. tostring(md.VorpallySauced and md.VorpallySauced._ ~= nil))
    if vps then
        add("    expanded.kills:      " .. tostring(vps.kills))
        add("    expanded.prefixId:   " .. tostring(vps.prefixId))
        add("    expanded.suffixId:   " .. tostring(vps.suffixId))
        add("    expanded.bondingId:  " .. tostring(vps.bondingId))
        add("    isFirearm:           " .. tostring(vps.isFirearm))
    else
        add("    (no VPS data — untracked)")
    end
end

local firearms = {}
local magazines = {}
for i = 0, items:size() - 1 do
    local it = items:get(i)
    local ft = it:getFullType() or ""
    if WD.isValidFirearm(it) then
        table.insert(firearms, it)
    end
    -- Magazines: detect by Clip in name or by VPS magazine tracking ModData
    if ft:lower():find("clip") or ft:lower():find("magazine") then
        table.insert(magazines, it)
    end
    -- Also catch by VPS magazine ModData markers
    local md = it:getModData()
    if md.VorpallySauced_appliedClipBonus or md.VorpallySauced_suffixName or md.VorpallySauced_sourceWeaponId then
        local already = false
        for _, m in ipairs(magazines) do if m == it then already = true; break end end
        if not already then table.insert(magazines, it) end
    end
end

add("")
add("--- FIREARMS (" .. #firearms .. ") ---")
for i, gun in ipairs(firearms) do
    dumpVPS("[" .. i .. "]", gun)
    -- Magazine inserted?
    local md = gun:getModData()
    add("    isContainsClip:      " .. tostring(gun.isContainsClip and gun:isContainsClip()))
    add("    currentAmmoCount:    " .. tostring(gun.getCurrentAmmoCount and gun:getCurrentAmmoCount()))
    add("    magazineType:        " .. tostring(gun.getMagazineType and gun:getMagazineType()))
    add("    runtime maxAmmo:     " .. tostring(gun.getMaxAmmo and gun:getMaxAmmo()))
    add("    runtime clipSize:    " .. tostring(gun.getClipSize and gun:getClipSize()))
    -- VPS magazine tracking on the GUN itself (pendingMagazineBonus, applied bonuses)
    add("    appliedClipBonus:    " .. tostring(md.VorpallySauced_appliedClipBonus))
    add("    pendingMagBonus:     " .. tostring(md.VorpallySauced_pendingMagazineBonus))
    add("    pendingMagSuffix:    " .. tostring(md.VorpallySauced_pendingMagazineSuffixName))
    add("    pendingMagBonding:   " .. tostring(md.VorpallySauced_pendingMagazineBondingName))
    add("")
end

add("--- MAGAZINES (" .. #magazines .. ") ---")
for i, mag in ipairs(magazines) do
    add("[" .. i .. "] " .. tostring(mag:getFullType()) ..
        " (id=" .. tostring(mag:getID()) .. ")")
    add("    runtime name:        " .. tostring(mag:getName()))
    add("    maxAmmo:             " .. tostring(mag.getMaxAmmo and mag:getMaxAmmo()))
    local md = mag:getModData()
    add("    VPS_appliedClipBonus:" .. tostring(md.VorpallySauced_appliedClipBonus))
    add("    VPS_originalMaxAmmo: " .. tostring(md.VorpallySauced_originalMaxAmmo))
    add("    VPS_suffixName:      " .. tostring(md.VorpallySauced_suffixName))
    add("    VPS_bondingName:     " .. tostring(md.VorpallySauced_bondingName))
    add("    VPS_sourceWeaponId:  " .. tostring(md.VorpallySauced_sourceWeaponId))
    add("")
end

return table.concat(lines, "\n")
