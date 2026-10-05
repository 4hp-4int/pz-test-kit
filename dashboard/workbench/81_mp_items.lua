--[[
    SousVide MP phase 2: items cross the Pass (docs/sousvide-mp.md).

    In MP every item exists TWICE, one copy per side. A side changes its copy
    and tells the other with the sync globals; the other side applies it to
    its own copy. These packets carry the engine's own bytes and apply the
    real handlers' logic, so the copies can disagree exactly as they do in
    game.

    | packet       | sender global(s)                      | applied as (real processClient / processServer)
    |--------------|---------------------------------------|------------------------------------------------
    | addItems     | sendAddItemToContainer(c, item)       | AddInventoryItemToContainerPacket: items from
    |              | sendAddItemsToContainer(c, list)      | CompressIdenticalItems bytes; an ID the container
    |              |   (server only, LuaManager:10335)     | already holds is NOT added: "Error: Dupe item ID"
    | removeItems  | sendRemoveItemFromContainer(c, item)  | client: removeItemWithID; server: Remove, or
    |              |   (server AND client, :10368)         | "already removed" (RemoveInventoryItemFromContainer)
    | replaceItem  | sendReplaceItemInContainer(c, o, n)   | remove old ID, add the new item's bytes
    | itemFields / | syncItemFields(player, item),         | the receiving side's copy with that ID takes the
    | itemModData  | syncItemModData(player, item)         | sent copy's condition/uses/name or ModData
    | ui           | (sendServerCommand "ui" is a command) |

    Containers are addressed the way ContainerID addresses them, as far as
    phase 2 needs: a player's main inventory (onlineID), or the container
    of an item somewhere in a player's inventory (a bag, a held cart) by that
    item's ID. World containers (squares, ground carts) are next.

    mpCensus{} lists every item on this side's players, recursively, with
    where it is and a fingerprint; dashboard/mp.js compares the sides.
]]

local try = WB.try
local M = WB.mp

-- ── addressing ─────────────────────────────────────────────────────────────
local function pidOf(player) return try(function() return player:getOnlineID() end) end

-- A container -> { t = "inv", pid } | { t = "item", pid, id } | nil, why
function M.addrOf(c)
    if not c then return nil, "no container" end
    local parent = try(function() return c:getParent() end)
    if parent and instanceof(parent, "IsoPlayer") then return { t = "inv", pid = pidOf(parent) } end
    local holder = try(function() return c:getContainingItem() end)
    if holder then
        local outer = try(function() return holder:getOutermostContainer() end)
        local op = outer and try(function() return outer:getParent() end)
        if op and instanceof(op, "IsoPlayer") then
            return { t = "item", pid = pidOf(op), id = holder:getID() }
        end
        if try(function() return holder:getWorldItem() end) then
            return nil, "a ground item's container (world addressing is not built yet)"
        end
    end
    return nil, "an unaddressed container (" .. tostring(try(function() return c:getType() end)) .. ")"
end

local function playerFor(pid)
    if M.role() == "server" then return M.byOnlineID(pid) end
    local me = M.players[1]
    if me and pidOf(me) == pid then return me end
end

function M.resolve(addr)
    if not addr then return nil, "no address" end
    local p = playerFor(addr.pid)
    if not p then return nil, "no player with onlineID " .. tostring(addr.pid) .. " on this side" end
    local inv = p:getInventory()
    if addr.t == "inv" then return inv end
    if addr.t == "item" then
        local holder = try(function() return inv:getItemWithIDRecursiv(addr.id) end)
        if not holder then return nil, "item " .. tostring(addr.id) .. " (the container's holder) is not in " .. tostring(p:getUsername()) .. "'s inventory here" end
        local c = try(function() return holder:getItemContainer() end)
        if not c then return nil, "item " .. tostring(addr.id) .. " has no container" end
        return c
    end
    return nil, "unknown address " .. tostring(addr.t)
end

local function baseAddrText(a)
    if not a then return "?" end
    return a.t == "inv" and ("inv#" .. tostring(a.pid)) or ("item " .. tostring(a.id) .. " in inv#" .. tostring(a.pid))
end
M.addrText = baseAddrText
local function addrText(a) return M.addrText(a) end   -- 82 extends it for world addresses

-- ── sending ────────────────────────────────────────────────────────────────
local function list(x)
    if type(x) == "table" then return x end
    local out = {}
    if x and x.size then for i = 0, x:size() - 1 do out[#out + 1] = x:get(i) end
    elseif x then out[1] = x end
    return out
end

local function queueItems(kind, c, items, extra)
    local addr, why = M.addrOf(c)
    local pkt = extra or {}
    pkt.kind, pkt.addr = kind, addr
    pkt.dir = M.role() == "server" and "down" or "up"
    -- a player's container goes to that player; nothing else is addressed yet
    -- a world container (no pid) goes to every client
    if pkt.dir == "down" and addr and addr.pid ~= nil then pkt.target = addr.pid + 1 end
    if not addr then pkt.unaddressed = why end
    pkt.ids, pkt.types = {}, {}
    for _, it in ipairs(items) do
        pkt.ids[#pkt.ids + 1] = it:getID()
        pkt.types[#pkt.types + 1] = tostring(it:getFullType())
    end
    if kind == "addItems" or kind == "replaceItem" then
        local enc = items
        if kind == "replaceItem" then enc = { items[2] } end
        local b64, err = PZEngine.itemsEncode(enc)
        pkt.b64, pkt.encodeError = b64, err
    end
    -- removes carry IDs, not item bytes (RemoveInventoryItemFromContainerPacket:
    -- a short count, then an int per ID)
    if kind == "removeItems" then pkt.size = 2 + 4 * #pkt.ids end
    pkt.module, pkt.command = "items", kind .. " " .. addrText(addr)
    M.queue(pkt)
end

M.installers[#M.installers + 1] = function(role)
    if role == "server" then
        sendAddItemToContainer = function(c, item) queueItems("addItems", c, { item }) end
        sendAddItemsToContainer = function(c, items) queueItems("addItems", c, list(items)) end
        sendReplaceItemInContainer = function(c, old, new) queueItems("replaceItem", c, { old, new }) end
        sendItemsInContainer = function(obj, c) queueItems("addItems", c or obj:getContainer(), list((c or obj:getContainer()):getItems())) end
    else
        -- server-only globals are no-ops on a client (LuaManager:10335, :10361)
        sendAddItemToContainer = function() end
        sendAddItemsToContainer = function() end
        sendReplaceItemInContainer = function() end
    end
    -- both sides may send removes (a client remove is LoginOnServer: legal)
    sendRemoveItemFromContainer = function(c, item) queueItems("removeItems", c, { item }) end
    sendRemoveItemsFromContainer = function(c, items) queueItems("removeItems", c, list(items)) end
    local function field(kind, player, item)
        local p = { kind = kind, dir = role == "server" and "down" or "up", id = item:getID(),
                    type = tostring(item:getFullType()), module = "items", command = kind .. " " .. tostring(item:getID()) }
        if p.dir == "down" then p.target = (pidOf(player) or -1) + 1 end
        if kind == "itemModData" then p.b64 = PZEngine.wireEncode(item:getModData()) end
        if kind == "itemFields" then
            p.fields = { condition = try(function() return item:getCondition() end),
                         uses = try(function() return item:getCurrentUses() end),
                         name = try(function() return item:getName() end) }
        end
        M.queue(p)
    end
    syncItemModData = function(player, item) if role == "server" then field("itemModData", player, item) end end
    syncItemFields = function(player, item) field("itemFields", player, item) end
end

-- ── applying ───────────────────────────────────────────────────────────────
local function result(p, events)
    return { listeners = 0, errors = {}, events = events, addr = addrText(p.addr) }
end

M.handlers.addItems = function(p)
    local c, why = M.resolve(p.addr)
    local ev = {}
    if not c then ev[1] = "UNRESOLVED container: " .. tostring(why) .. " (the real handler drops the packet)"; return result(p, ev) end
    local items, err = PZEngine.itemsDecode(p.b64)
    if not items then ev[1] = "decode failed: " .. tostring(err); return result(p, ev) end
    for _, it in ipairs(items) do
        if c:containsID(it:getID()) then
            ev[#ev + 1] = "Error: Dupe item ID. id = " .. it:getID() .. " (not added: the container already holds it)"
        else
            c:addItem(it)
            ev[#ev + 1] = "added " .. tostring(it:getFullType()) .. " #" .. it:getID()
        end
    end
    try(function() c:setExplored(true) end)
    return result(p, ev)
end

M.handlers.removeItems = function(p)
    local c, why = M.resolve(p.addr)
    local ev = {}
    if not c then ev[1] = "UNRESOLVED container: " .. tostring(why); return result(p, ev) end
    for _, id in ipairs(p.ids or {}) do
        local it = c:getItemWithID(id)
        if not it then
            ev[#ev + 1] = "already removed: #" .. id
        elseif M.role() == "server" then
            c:Remove(it); ev[#ev + 1] = "removed #" .. id
        else
            c:removeItemWithID(id); ev[#ev + 1] = "removed #" .. id
        end
    end
    try(function() c:setExplored(true) end)
    return result(p, ev)
end

M.handlers.replaceItem = function(p)
    local c, why = M.resolve(p.addr)
    local ev = {}
    if not c then ev[1] = "UNRESOLVED container: " .. tostring(why); return result(p, ev) end
    local old = p.ids and p.ids[1]
    if old and c:getItemWithID(old) then c:removeItemWithID(old); ev[#ev + 1] = "removed old #" .. old end
    local items = PZEngine.itemsDecode(p.b64) or {}
    for _, it in ipairs(items) do
        if c:containsID(it:getID()) then ev[#ev + 1] = "Error: Dupe item ID. id = " .. it:getID()
        else c:addItem(it); ev[#ev + 1] = "added #" .. it:getID() end
    end
    return result(p, ev)
end

local function findAnywhere(id)
    for _, pl in ipairs(M.players) do
        local it = try(function() return pl:getInventory():getItemWithIDRecursiv(id) end)
        if it then return it end
    end
end

M.handlers.itemModData = function(p)
    local it = findAnywhere(p.id)
    if not it then return result(p, { "no item #" .. tostring(p.id) .. " on this side" }) end
    local md = PZEngine.wireDecode(p.b64) or {}
    local dst = it:getModData()
    for k in pairs(dst) do dst[k] = nil end
    for k, v in pairs(md) do dst[k] = v end
    return result(p, { "ModData of #" .. p.id .. " replaced" })
end

M.handlers.itemFields = function(p)
    local it = findAnywhere(p.id)
    if not it then return result(p, { "no item #" .. tostring(p.id) .. " on this side" }) end
    local f = p.fields or {}
    if f.condition then try(function() it:setCondition(f.condition) end) end
    if f.uses then try(function() it:setCurrentUses(f.uses) end) end
    if f.name then try(function() it:setName(f.name) end) end
    return result(p, { "fields of #" .. p.id .. " set" })
end

-- ── census ─────────────────────────────────────────────────────────────────
local function hashModData(md)
    local keys = {}
    local function walk(t, prefix, depth)
        if depth > 4 then return end
        for k, v in pairs(t) do
            if type(v) == "table" then walk(v, prefix .. tostring(k) .. ".", depth + 1)
            elseif type(v) ~= "function" and type(v) ~= "userdata" then keys[#keys + 1] = prefix .. tostring(k) .. "=" .. tostring(v) end
        end
    end
    if type(md) == "table" then walk(md, "", 0) end
    table.sort(keys)
    return table.concat(keys, ";")
end

WB.register("mpCensus", function()
    local out = {}
    local function walk(c, at, pid, depth)
        if depth > 6 or not c then return end
        local items = c:getItems()
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            out[#out + 1] = { id = it:getID(), type = tostring(it:getFullType()), at = at, pid = pid,
                              condition = try(function() return it:getCondition() end),
                              uses = try(function() return it:getCurrentUses() end),
                              md = hashModData(try(function() return it:getModData() end)) }
            local inner = try(function() return it:getItemContainer() end)
            if inner then walk(inner, at .. " > " .. tostring(it:getType()) .. "#" .. it:getID(), pid, depth + 1) end
        end
    end
    for _, p in ipairs(M.players) do
        local pid = pidOf(p)
        walk(p:getInventory(), tostring(p:getUsername()), pid, 0)
    end
    return { role = M.role(), items = out }
end)
