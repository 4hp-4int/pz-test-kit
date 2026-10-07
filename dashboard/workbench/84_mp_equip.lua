--[[
    SousVide MP: the Equip packet crosses the Pass (zombie/network/packets/
    EquipPacket.java, 42.21).

    The server's sendEquip(player) (LuaManager:3905) calls updateHandEquips,
    which sends Equip to every client near the player (IsoGameCharacter:9439).
    The OWNING client does not trust the bytes: it looks each hand item up by
    ID in ITS OWN inventory (EquipPacket.parse :106-112). An ID it does not
    hold yet gives a nil hand, the "equipped unknown item type" user log, and
    the rest of the packet is skipped. processClient (:162-168) then echoes
    the client's CURRENT hands to the server, and the server's processServer
    (:171-185) sets its hands from them.

    Equip rides ordering channel 0 and AddInventoryItemToContainer channel 1
    (their @PacketSetting): RakNet keeps order only within a channel, so an
    Equip can overtake the add of the very item it names. The Pass's
    {swap: true} pump control replays that.

    Packets:  equip (down)      the hands, by item ID (+ types, for reading)
              equipEcho (up)    the owning client's hands after applying it
    Not modelled: other clients (they load the item from the packet's bytes
    for visuals only; their copy of the player's hands never matters here).
]]

local try = WB.try
local M = WB.mp

local function pidOf(p) return try(function() return p:getOnlineID() end) end
local function idOf(it) return it and it:getID() or -1 end

M.installers[#M.installers + 1] = function(role)
    if role == "server" then
        sendEquip = function(player)
            local p1, p2 = player:getPrimaryHandItem(), player:getSecondaryHandItem()
            local pid = pidOf(player)
            M.queue({
                kind = "equip", dir = "down", pid = pid, target = pid and pid + 1 or nil,
                primary = idOf(p1),
                secondary = (p2 and p2 == p1) and "same" or idOf(p2),
                types = { p1 and tostring(p1:getFullType()) or "-", p2 and tostring(p2:getFullType()) or "-" },
                module = "player", command = "equip " .. idOf(p1) .. "/" .. ((p2 and p2 == p1) and "same" or idOf(p2)),
                size = 16,
            })
        end
    else
        -- a client's own equips go up through the vanilla actions; the Pass
        -- only needs the server -> owner direction and the echo
        sendEquip = function() end
    end
end

-- NOTE: getTimestampMs stays the kit's mock (0) in MP sessions. A scenario
-- that needs real milliseconds sets it on its own side:
--   getTimestampMs = function() return math.floor(os.time() * 1000) end
-- Installing the real clock for every session (briefly, 2026-10-06) let
-- VorpallySauced's client notification cooldowns pass for the first time
-- and broke its genome_kill_parity check: the client VM was lost on the next
-- delivery. Real time is a per-scenario choice, not a bench default.
-- (Cause, pinned 2026-10-07: bench clients lacked the ColorRGB global, so
-- each notification made a failed Java call that broke the VM's next one;
-- 80_mp.lua now exposes it, and that scenario passes on a real client clock.)

local function result(events) return { listeners = 0, errors = {}, events = events } end

-- The owning client applies EquipPacket.parse, then processClient echoes.
M.handlers.equip = function(p)
    local me = M.players[1]
    local ev = {}
    if not (me and pidOf(me) == p.pid) then
        ev[1] = "remote player: visuals only (not modelled)"
        return result(ev)
    end
    local inv = me:getInventory()
    local stop = false
    if p.primary == -1 then
        me:setPrimaryHandItem(nil)
        ev[#ev + 1] = "primary: nothing"
    else
        local it = inv:getItemWithID(p.primary)
        me:setPrimaryHandItem(it)
        if it then
            ev[#ev + 1] = "primary: #" .. p.primary .. " " .. tostring(it:getFullType())
        else
            ev[#ev + 1] = "primary: #" .. p.primary .. " NOT in this inventory -> hand set to nil; user log: equipped unknown item type"
            stop = true
        end
    end
    if not stop then
        if p.secondary == -1 then
            me:setSecondaryHandItem(nil)
        elseif p.secondary == "same" then
            me:setSecondaryHandItem(me:getPrimaryHandItem())
        else
            local it = inv:getItemWithID(p.secondary)
            me:setSecondaryHandItem(it)
            if not it then ev[#ev + 1] = "secondary: #" .. p.secondary .. " NOT in this inventory -> nil" end
        end
    end
    -- processClient: echo what the hands are NOW
    local h1, h2 = me:getPrimaryHandItem(), me:getSecondaryHandItem()
    M.queue({ kind = "equipEcho", dir = "up", pid = p.pid, primary = idOf(h1), secondary = idOf(h2),
              module = "player", command = "equip echo " .. idOf(h1) .. "/" .. idOf(h2), size = 16 })
    ev[#ev + 1] = "echoed hands up: " .. idOf(h1) .. "/" .. idOf(h2)
    return result(ev)
end

-- The server applies processServer.
M.handlers.equipEcho = function(p)
    local player = M.byOnlineID(p.pid)
    local ev = {}
    if not player then ev[1] = "no such player"; return result(ev) end
    local inv = player:getInventory()
    if p.primary == -1 then player:setPrimaryHandItem(nil) else player:setPrimaryHandItem(inv:getItemWithID(p.primary)) end
    if p.secondary == -1 then
        player:setSecondaryHandItem(nil)
    elseif p.secondary == p.primary then
        player:setSecondaryHandItem(player:getPrimaryHandItem())
    else
        player:setSecondaryHandItem(inv:getItemWithID(p.secondary))
    end
    ev[1] = "server hands now " .. idOf(player:getPrimaryHandItem()) .. "/" .. idOf(player:getSecondaryHandItem())
    return result(ev)
end
