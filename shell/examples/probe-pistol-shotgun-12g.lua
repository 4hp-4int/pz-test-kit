-- Diagnose the user's pistol_shotgun_12g (GGS) Blooded "of the Arsenal" report:
--   - internal mag readout 0/17
--   - tooltip bonus +0 (separate formatStatValue bug, fixed)
--   - clip still holds 8 (this probe)
-- Reports the full clipSize derivation chain on every firearm in the
-- equipped player's inventory so we can see what getEffectiveMagBase /
-- applyStat / Reset is actually doing on this specific gun.

local WeaponData = VorpallySauced.WeaponData
local out = { "=== pistol_shotgun_12g (GGS) clipSize derivation ===" }

local function push(s) out[#out+1] = s end

local function safeCall(o, m, ...)
    if not o or not o[m] then return nil end
    local ok, r = pcall(o[m], o, ...)
    if ok then return r end
    return nil
end

local function inspect(weapon, label)
    if not weapon or not safeCall(weapon, "isRanged") then return end
    if not safeCall(weapon, "isRanged") then return end

    local script = safeCall(weapon, "getScriptItem")
    local fullName = script and safeCall(script, "getFullName") or "?"

    push("")
    push(string.format("[%s] %s (id=%s)", label, fullName, tostring(weapon:getID())))

    -- Script-level base
    local origClip = WeaponData.getOriginalStat(weapon, "clipSize") or "?"
    local origMax  = WeaponData.getOriginalStat(weapon, "maxAmmo") or "?"
    push(string.format("  originalStats: clipSize=%s maxAmmo=%s", tostring(origClip), tostring(origMax)))

    -- Live Java getters
    local liveClip = safeCall(weapon, "getClipSize") or "?"
    local liveMax  = safeCall(weapon, "getMaxAmmo") or "?"
    local liveMagType = safeCall(weapon, "getMagazineType") or "?"
    push(string.format("  live: getClipSize=%s getMaxAmmo=%s getMagazineType=%s",
        tostring(liveClip), tostring(liveMax), tostring(liveMagType)))

    -- Coexistence detection
    local isDyn = VorpallySauced.isDynamicCapacityWeapon
        and VorpallySauced.isDynamicCapacityWeapon(weapon)
    local dmt = VorpallySauced.getDynamicMagazineType
        and VorpallySauced.getDynamicMagazineType(weapon)
    push(string.format("  isDynamicCapacityWeapon=%s  getDynamicMagazineType=%s",
        tostring(isDyn), tostring(dmt)))

    -- Resolve dynamic mag's capacity
    if dmt then
        local ok, m = pcall(instanceItem, dmt)
        if ok and m and m.getMaxAmmo then
            push(string.format("    dynamic mag instance maxAmmo=%s", tostring(m:getMaxAmmo())))
        else
            push("    dynamic mag instance FAILED (instanceItem nil)")
        end
    end

    -- Clip WeaponPart
    if weapon.getWeaponPart then
        local clip = weapon:getWeaponPart("Clip")
        if clip then
            local pm = safeCall(clip, "getMaxAmmo")
            local pc = safeCall(clip, "getClipSize")
            local pn = safeCall(clip, "getName")
            push(string.format("  Clip WeaponPart: name=%s getMaxAmmo=%s getClipSize=%s",
                tostring(pn), tostring(pm), tostring(pc)))
        else
            push("  Clip WeaponPart: (none)")
        end
    end

    -- The single source of truth
    local effBase = WeaponData.getEffectiveMagBase and WeaponData.getEffectiveMagBase(weapon)
    push(string.format("  getEffectiveMagBase=%s", tostring(effBase)))

    -- VPS data
    local data = WeaponData.getModData(weapon)
    if data then
        push(string.format("  VPS: prefixId=%s suffixId=%s bondingId=%s",
            tostring(data.prefixId), tostring(data.suffixId), tostring(data.bondingId)))
        local rt = WeaponData.rt(data.weaponId or 0)
        push(string.format("  VPS runtime: appliedClipBonus=%s pendingMagazineBonus=%s",
            tostring(rt and rt.appliedClipBonus), tostring(data.pendingMagazineBonus)))

        local calc = WeaponData.calculateClipSizeBonus and WeaponData.calculateClipSizeBonus(weapon)
        push(string.format("  calculateClipSizeBonus=%s", tostring(calc)))

        local exp = WeaponData.getExpectedClipSize and WeaponData.getExpectedClipSize(weapon)
        push(string.format("  getExpectedClipSize=%s   (vs liveClip=%s)", tostring(exp), tostring(liveClip)))
    else
        push("  VPS: (no data)")
    end
end

-- Dedi: walk online players (getSpecificPlayer(0) is nil server-side)
local players = {}
if isServer() then
    local online = getOnlinePlayers()
    if online then
        for i = 0, online:size() - 1 do
            players[#players+1] = online:get(i)
        end
    end
else
    local p = getSpecificPlayer(0)
    if p then players[#players+1] = p end
end

push(string.format("players found: %d  (isServer=%s)", #players, tostring(isServer())))

for _, player in ipairs(players) do
    local uname = (player.getUsername and player:getUsername()) or "?"
    push("")
    push(string.format("==== PLAYER: %s ====", uname))

    local primary = player:getPrimaryHandItem()
    inspect(primary, "PRIMARY")

    local inv = player:getInventory()
    if inv then
        local items = inv:getItems()
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            if it ~= primary and it.isRanged and it:isRanged() then
                inspect(it, "INV")
            end
        end
    end
end

return table.concat(out, "\n")
