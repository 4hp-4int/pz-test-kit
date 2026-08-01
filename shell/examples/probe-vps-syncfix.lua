-- Live validation of the proposed fix: sync weapon ModData server->client on
-- EVERY kill (not every 5th). Wraps WeaponData.incrementKills: after the
-- increment, compact + syncItemModData to the holding player so the client's
-- authoritative inventory copy stays current and can't regress the count.
--
--   eval -f probe-vps-syncfix.lua   -> install / status

local WD = VorpallySauced and VorpallySauced.WeaponData
if not WD then return "no WeaponData" end

_SYNCFIX = _SYNCFIX or { n = 0 }

local function holderOf(weaponId)
    local ok, players = pcall(getOnlinePlayers)
    if not ok or not players then return nil end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p then
            local h = p:getPrimaryHandItem()
            if h and h:getID() == weaponId then return p end
            local inv = p:getInventory()
            if inv and inv:getItemById(weaponId) then return p end
        end
    end
    return nil
end

if not _SYNCFIX.installed then
    local o_inc = WD.incrementKills
    WD.incrementKills = function(weapon)
        local nk = o_inc(weapon)
        if weapon then
            local p = holderOf(weapon:getID())
            if p then
                WD.compactModData(weapon)
                syncItemModData(p, weapon)
                _SYNCFIX.n = _SYNCFIX.n + 1
                _SYNCFIX.last = (p:getUsername() or "?") .. " kills=" .. tostring(nk)
            end
        end
        return nk
    end
    _SYNCFIX.installed = true
    return "syncfix installed (every-kill server->client sync emulated)"
end

return "syncfix active; synced " .. _SYNCFIX.n .. " kill(s); last=" .. tostring(_SYNCFIX.last)
