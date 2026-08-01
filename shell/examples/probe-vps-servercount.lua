-- Read the connected player's equipped-weapon VPS ModData SERVER-SIDE.
-- Compares server truth vs client verifyStats to localize credit-drop:
--   server kills == client  -> all good
--   server kills  > client  -> server credits, client SYNC drops
--   server kills  < expected -> onZombieDead bails before incrementKills

local out = {}
local players = getOnlinePlayers()
if not players or players:size() == 0 then
    return "no online players (is the client connected?)"
end

local WD = VorpallySauced and VorpallySauced.WeaponData
for i = 0, players:size() - 1 do
    local p = players:get(i)
    local name = p and (p:getUsername() or ("p" .. i)) or "?"
    local w = p and p:getPrimaryHandItem()
    if not w then
        out[#out + 1] = name .. ": no primary hand item"
    else
        local wid = tostring(w:getID())
        local disp = w:getDisplayName()
        local data = WD and WD.getModData(w)
        if not data then
            out[#out + 1] = string.format("%s: %s (wid=%s) -> NO VPS ModData", name, disp, wid)
        else
            out[#out + 1] = string.format(
                "%s: %s (wid=%s) -> kills=%s prefix=%s suffix=%s bonding=%s isFirearm=%s",
                name, disp, wid,
                tostring(data.kills), tostring(data.prefixId), tostring(data.suffixId),
                tostring(data.bondingId), tostring(data.isFirearm))
        end
    end
end

return table.concat(out, "  ||  ")
