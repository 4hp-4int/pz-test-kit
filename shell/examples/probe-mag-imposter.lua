-- Read-only diagnostic: dump every magazine-like item in the player's
-- inventory + the equipped firearm's state, identifying possible "imposter"
-- mags (raw fullname display, no VPS modData, duplicate IDs/types).

local WeaponData = VorpallySauced.WeaponData
local MagazineSync = VorpallySauced.MagazineSync
local out = { "=== Magazine imposter probe ===" }
local function push(s) out[#out+1] = s end
local function safe(o, m, ...)
    if not o or not o[m] then return nil end
    local ok, r = pcall(o[m], o, ...)
    if ok then return r end
    return nil
end

local function dumpMag(m, label)
    local s = safe(m, "getScriptItem")
    local full = s and safe(s, "getFullName") or "?"
    local sdn = s and safe(s, "getDisplayName") or "?"
    local idn = safe(m, "getDisplayName") or "?"
    local name = safe(m, "getName") or "?"
    local maxA = safe(m, "getMaxAmmo") or "?"
    local clip = safe(m, "getClipSize") or "?"
    local cur = safe(m, "getCurrentAmmoCount") or "?"
    local id = safe(m, "getID") or "?"
    push(string.format("[%s] id=%s full=%s sdn=%q idn=%q name=%q maxAmmo=%s clipSize=%s cur=%s",
        label, tostring(id), full, tostring(sdn), tostring(idn), tostring(name),
        tostring(maxA), tostring(clip), tostring(cur)))

    -- VPS magazine modData
    local md = m.getModData and m:getModData()
    if md then
        local vpsKeys = {
            "VorpallySauced_MagazineAppliedBonus",
            "VorpallySauced_MagazineSuffixId",
            "VorpallySauced_MagazineBondingId",
            "VorpallySauced_MagazineSourceWeapon",
            "VorpallySauced_MagazineSuffix",
            "VorpallySauced_MagazineBonding",
            "VorpallySauced_clipBonus",
            "appliedClipBonus",
        }
        local parts = {}
        for _, k in ipairs(vpsKeys) do
            if md[k] ~= nil then parts[#parts+1] = k .. "=" .. tostring(md[k]) end
        end
        if #parts > 0 then push("    VPS modData: " .. table.concat(parts, " ")) end
    end

    -- Clean-name pipeline
    if WeaponData and WeaponData.cleanItemName then
        push("    cleanItemName -> " .. tostring(WeaponData.cleanItemName(m, "Magazine")))
    end
end

local function dumpGun(g, label)
    local s = safe(g, "getScriptItem")
    local full = s and safe(s, "getFullName") or "?"
    push("")
    push(string.format("[%s GUN] %s id=%s", label, full, tostring(safe(g, "getID"))))
    push(string.format("  live: getClipSize=%s getMaxAmmo=%s getMagazineType=%s containsClip=%s curAmmo=%s",
        tostring(safe(g, "getClipSize")), tostring(safe(g, "getMaxAmmo")),
        tostring(safe(g, "getMagazineType")), tostring(safe(g, "isContainsClip")),
        tostring(safe(g, "getCurrentAmmoCount"))))

    local origMax = WeaponData.getOriginalStat(g, "maxAmmo") or "?"
    local origClip = WeaponData.getOriginalStat(g, "clipSize") or "?"
    push(string.format("  originalStats: clipSize=%s maxAmmo=%s", tostring(origClip), tostring(origMax)))

    local isDyn = VorpallySauced.isDynamicCapacityWeapon and VorpallySauced.isDynamicCapacityWeapon(g)
    local dmt = VorpallySauced.getDynamicMagazineType and VorpallySauced.getDynamicMagazineType(g)
    push(string.format("  isDynamicCapacityWeapon=%s getDynamicMagazineType=%s",
        tostring(isDyn), tostring(dmt)))

    if dmt then
        local ok, m = pcall(instanceItem, dmt)
        if ok and m and m.getMaxAmmo then
            push(string.format("    instanceItem(dmt) maxAmmo=%s", tostring(m:getMaxAmmo())))
        end
    end

    if g.getWeaponPart then
        local clip = g:getWeaponPart("Clip")
        if clip then
            push(string.format("  Clip WeaponPart: name=%s maxAmmo=%s clipSize=%s id=%s",
                tostring(safe(clip, "getName")), tostring(safe(clip, "getMaxAmmo")),
                tostring(safe(clip, "getClipSize")), tostring(safe(clip, "getID"))))
        else
            push("  Clip WeaponPart: (none)")
        end
    end

    local effBase = WeaponData.getEffectiveMagBase and WeaponData.getEffectiveMagBase(g)
    push(string.format("  getEffectiveMagBase=%s", tostring(effBase)))

    local d = WeaponData.getModData(g)
    if d then
        push(string.format("  VPS data: prefixId=%s suffixId=%s bondingId=%s pendingMagBonus=%s",
            tostring(d.prefixId), tostring(d.suffixId), tostring(d.bondingId),
            tostring(d.pendingMagazineBonus)))
        local rt = WeaponData.rt(d.weaponId or 0)
        push(string.format("  VPS runtime: appliedClipBonus=%s", tostring(rt and rt.appliedClipBonus)))
        push(string.format("  calculateClipSizeBonus=%s",
            tostring(WeaponData.calculateClipSizeBonus and WeaponData.calculateClipSizeBonus(g))))
        push(string.format("  getExpectedClipSize=%s",
            tostring(WeaponData.getExpectedClipSize and WeaponData.getExpectedClipSize(g))))
    end
end

local players = {}
if isServer() then
    local online = getOnlinePlayers()
    if online then for i = 0, online:size() - 1 do players[#players+1] = online:get(i) end end
else
    local p = getSpecificPlayer(0); if p then players[#players+1] = p end
end

for _, player in ipairs(players) do
    push(string.format("==== PLAYER: %s ====", tostring(safe(player, "getUsername"))))

    local primary = player:getPrimaryHandItem()
    if primary and safe(primary, "isRanged") then
        dumpGun(primary, "PRIMARY")
    end

    push("")
    push("---- INVENTORY MAG-LIKE ITEMS (every item with maxAmmo>0 OR magazine in name) ----")
    local inv = player:getInventory()
    if inv then
        local items = inv:getItems()
        local seenByType = {}  -- detect duplicates of same script type
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            local s = it.getScriptItem and it:getScriptItem()
            local full = s and s.getFullName and s:getFullName() or ""
            local maxA = (it.getMaxAmmo and it:getMaxAmmo()) or 0
            local isMagLike = maxA > 0 and not (it.isRanged and it:isRanged())
            if isMagLike then
                dumpMag(it, "MAG")
                seenByType[full] = (seenByType[full] or 0) + 1
            end
        end
        push("")
        push("---- Duplicate scriptType counts (>1 means multiple of same fullname) ----")
        for k, v in pairs(seenByType) do
            if v > 1 then push("  " .. k .. " x" .. v) end
        end
    end
end

return table.concat(out, "\n")
