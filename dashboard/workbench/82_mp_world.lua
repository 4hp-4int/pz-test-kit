--[[
    SousVide MP phase 2b: the world crosses the Pass (docs/sousvide-mp.md).

    Both sides load the same map area (mpWorld). World changes are
    transmitted by METHODS on Java objects, not globals, so they are caught
    where PZ mods hook Java: __classmetatables (Lua->Java calls only, which is
    every mod and vanilla Lua call site).

    | packet      | sender (server unless noted)                 | applied as (real handler)
    |-------------|-----------------------------------------------|----------------------------------------
    | worldAdd    | obj:transmitCompleteItemToClients()           | AddItemToMapPacket: the object's own bytes
    |             | sq:AddWorldInventoryItem(item, x, y, h[, true])| (writeToRemoteBuffer / createFromBuffer +
    |             |   (the 4-arg form transmits INSIDE Java, which | loadFromRemoteBuffer puts it on its square
    |             |   a Lua hook can't see: wrapped here)          | at the sent index), then addToWorld();
    |             |                                               | OnContainerUpdate + OnObjectAdded fire
    | worldRemove | sq:transmitRemoveItemFromSquare(obj)          | RemoveItemFromSquarePacket: the object AT
    |             |   (server: sends obj:getObjectIndex(), then    | THE SENT INDEX in the square's object list
    |             |   removes locally; client: local remove only)  | is removed -- if the client's list order
    |             |                                               | differs, the WRONG object goes
    | items (81)  | add/remove/replace into a world container     | containers addressed by square:
    |             |                                               | ground item (its item ID) or object
    |             |                                               | (object index + container index)

    mpWorld{x, y, r}   load the map box on this side, and watch it (census)
    mpPlace{pid, x, y, z} put a player there (the owning client and the server
                       both move their copy, as a player update would)
    The census (81) also walks every watched square: ground items, their
    containers, and object containers.
]]

local try = WB.try
local M = WB.mp
M.watch = M.watch or {}

local function inServer(fn)
    local prev = PZEngine.setServer(true)
    local res = { pcall(fn) }
    PZEngine.setServer(prev)
    if not res[1] then error(res[2], 0) end
    return unpack(res, 2)
end

local function square(x, y, z)
    return inServer(function() return PZEngine.cell():getGridSquare(x, y, z or 0) end)
end
M.square = square

-- ── addressing (extends 81's) ──────────────────────────────────────────────
local baseAddr, baseResolve = M.addrOf, M.resolve

function M.addrOf(c)
    local a, why = baseAddr(c)
    if a then return a end
    local holder = try(function() return c:getContainingItem() end)
    local wi = holder and try(function() return holder:getWorldItem() end)
    if wi then
        local sq = wi:getSquare()
        return { t = "ground", id = holder:getID(), x = sq:getX(), y = sq:getY(), z = sq:getZ() }
    end
    local parent = try(function() return c:getParent() end)
    local sq = parent and try(function() return parent:getSquare() end)
    if sq then
        return { t = "object", x = sq:getX(), y = sq:getY(), z = sq:getZ(),
                 index = parent:getObjectIndex(), ci = parent:getContainerIndex(c) }
    end
    return nil, why
end

function M.resolve(addr)
    if not addr or (addr.t ~= "ground" and addr.t ~= "object") then return baseResolve(addr) end
    local sq = square(addr.x, addr.y, addr.z)
    if not sq then return nil, "no square " .. addr.x .. "," .. addr.y .. "," .. addr.z .. " loaded on this side" end
    if addr.t == "ground" then
        local objs = sq:getWorldObjects()
        for i = 0, objs:size() - 1 do
            local it = objs:get(i):getItem()
            if it and it:getID() == addr.id then
                local c = try(function() return it:getItemContainer() end)
                if c then return c end
                return nil, "ground item " .. addr.id .. " has no container"
            end
        end
        return nil, "no ground item " .. addr.id .. " at " .. addr.x .. "," .. addr.y .. " on this side"
    end
    local objs = sq:getObjects()
    if addr.index < 0 or addr.index >= objs:size() then return nil, "no object at index " .. addr.index end
    local c = objs:get(addr.index):getContainerByIndex(addr.ci or 0)
    if not c then return nil, "object " .. addr.index .. " has no container " .. tostring(addr.ci) end
    return c
end

-- world addresses go to every client (the real server sends to clients in range)
local baseText = M.addrText
function M.addrText(a)
    if a and a.t == "ground" then return "ground item " .. a.id .. " @" .. a.x .. "," .. a.y end
    if a and a.t == "object" then return "object " .. a.index .. "/" .. tostring(a.ci) .. " @" .. a.x .. "," .. a.y end
    return baseText and baseText(a) or "?"
end

-- ── the transmit methods ───────────────────────────────────────────────────
local function watchSquare(x, y, z) M.watch[x .. "," .. y .. "," .. (z or 0)] = { x = x, y = y, z = z or 0 } end

local function queueWorldAdd(obj, why)
    local sq = obj:getSquare()
    local b64, err = PZEngine.objectEncode(obj)
    local item = try(function() return obj:getItem() end)
    watchSquare(sq:getX(), sq:getY(), sq:getZ())
    M.queue({ kind = "worldAdd", dir = M.role() == "server" and "down" or "up", b64 = b64, encodeError = err,
              x = sq:getX(), y = sq:getY(), z = sq:getZ(), index = obj:getObjectIndex(),
              itemId = item and item:getID() or nil, type = item and tostring(item:getFullType()) or tostring(obj:getObjectName()),
              module = "world", command = "add " .. (item and tostring(item:getFullType()) or tostring(obj:getObjectName())) .. " @" .. sq:getX() .. "," .. sq:getY() .. (why and (" (" .. why .. ")") or "") })
end

local function override(cls, name, fn)
    local mt = cls and __classmetatables and __classmetatables[cls.class]
    if not (mt and type(mt.__index) == "table") then return nil end
    local orig = mt.__index[name]
    mt.__index[name] = function(...) return fn(orig, ...) end
    return orig
end

M.installers[#M.installers + 1] = function(role)
    if M.worldHooked then return end
    M.worldHooked = true
    local function addHook(orig, self)
        if role == "server" then queueWorldAdd(self) end   -- a client's copy is a no-op (not GameServer.server)
    end
    override(IsoWorldInventoryObject, "transmitCompleteItemToClients", addHook)
    override(IsoObject, "transmitCompleteItemToClients", addHook)
    local function toServer(orig, self) if role == "client" then queueWorldAdd(self, "client to server") end end
    override(IsoWorldInventoryObject, "transmitCompleteItemToServer", toServer)
    override(IsoObject, "transmitCompleteItemToServer", toServer)

    override(IsoGridSquare, "transmitRemoveItemFromSquare", function(orig, sq, obj, safely)
        if not obj or not sq:getObjects():contains(obj) then return -1 end
        if role ~= "server" then return sq:RemoveTileObject(obj) end   -- client: local only (:5998)
        local index = obj:getObjectIndex()
        local item = try(function() return obj:getItem() end)
        watchSquare(sq:getX(), sq:getY(), sq:getZ())
        M.queue({ kind = "worldRemove", dir = "down", x = sq:getX(), y = sq:getY(), z = sq:getZ(), index = index,
                  itemId = item and item:getID() or nil, module = "world",
                  command = "remove #" .. index .. (item and (" (" .. tostring(item:getFullType()) .. " " .. item:getID() .. ")") or "") .. " @" .. sq:getX() .. "," .. sq:getY() })
        -- and the server's own copy goes (RemoveItemFromSquarePacket.removeItemFromMap)
        sq:RemoveTileObject(obj)
        if item then try(function() item:setWorldItem(nil) end) end
        return index
    end)

    -- AddWorldInventoryItem(item, x, y, h) transmits from inside Java (where
    -- this hook can't see it): add without, then transmit through the Pass.
    override(IsoGridSquare, "AddWorldInventoryItem", function(orig, sq, item, x, y, h, transmit, ...)
        if type(item) == "string" or transmit == false or role ~= "server" then
            return orig(sq, item, x, y, h, transmit, ...)
        end
        local res = orig(sq, item, x, y, h, false, ...)
        local wi = res and try(function() return res:getWorldItem() end)
        if wi then queueWorldAdd(wi, "AddWorldInventoryItem") end
        return res
    end)
end

-- ── applying ───────────────────────────────────────────────────────────────
M.handlers.worldAdd = function(p)
    local ev = {}
    if not p.b64 then return { events = { "no bytes: " .. tostring(p.encodeError) } } end
    if p.itemId then
        local sq = square(p.x, p.y, p.z)
        local objs = sq and sq:getWorldObjects()
        for i = 0, (objs and objs:size() or 0) - 1 do
            local it = objs:get(i):getItem()
            if it and it:getID() == p.itemId then return { events = { "already on the square: ground item " .. p.itemId .. " (not added twice)" } } end
        end
    end
    local obj, err = inServer(function() return PZEngine.objectDecode(p.b64) end)
    if not obj then return { events = { "decode failed: " .. tostring(err) } } end
    if not try(function() return obj:getSquare() end) then return { events = { "UNRESOLVED: square " .. p.x .. "," .. p.y .. " not loaded on this side" } } end
    try(function() obj:addToWorld() end)
    watchSquare(p.x, p.y, p.z)
    ev[#ev + 1] = "added " .. tostring(p.type) .. " at index " .. tostring(try(function() return obj:getObjectIndex() end))
    local fired = 0
    for _, name in ipairs({ "OnContainerUpdate", "OnObjectAdded" }) do
        local evt = rawget(Events, name)
        for _, fn in ipairs((evt and evt._listeners) or {}) do
            local ok, e = pcall(fn, obj)
            fired = fired + 1
            if not ok then ev[#ev + 1] = name .. " listener " .. M.where(fn) .. ": " .. tostring(e) end
        end
    end
    if fired > 0 then ev[#ev + 1] = fired .. " OnContainerUpdate/OnObjectAdded listener call(s)" end
    return { events = ev }
end

M.handlers.worldRemove = function(p)
    local sq = square(p.x, p.y, p.z)
    if not sq then return { events = { "UNRESOLVED: square not loaded" } } end
    local objs = sq:getObjects()
    if p.index < 0 or p.index >= objs:size() then return { events = { "invalid index " .. p.index .. " (" .. objs:size() .. " objects here): nothing removed" } } end
    local o = objs:get(p.index)
    local it = try(function() return o:getItem() end)
    local ev = {}
    if p.itemId and (not it or it:getID() ~= p.itemId) then
        ev[#ev + 1] = "WRONG OBJECT: index " .. p.index .. " holds " .. (it and (tostring(it:getFullType()) .. " " .. it:getID()) or tostring(o:getObjectName())) .. ", not item " .. p.itemId .. " -- removed anyway (the real handler goes by index)"
    end
    sq:RemoveTileObject(o)
    if it then try(function() it:setWorldItem(nil) end) end
    ev[#ev + 1] = "removed index " .. p.index
    return { events = ev }
end

-- ── setup tools ────────────────────────────────────────────────────────────
WB.register("mpWorld", function(a)
    local x, y, r = math.floor(a.x), math.floor(a.y), math.floor(a.r or 3)
    local res = WB.tools.worldArea({ x = x, y = y, r = math.max(r, 8) })
    for dx = -r, r do for dy = -r, r do watchSquare(x + dx, y + dy, a.z or 0) end end
    return { chunks = res.chunks, watched = (2 * r + 1) ^ 2 }
end)

WB.register("mpPlace", function(a)
    local p
    if M.role() == "server" then p = M.byOnlineID(a.pid or 0) else p = M.players[1] end
    if not p then error("no player " .. tostring(a.pid), 0) end
    local sq = square(math.floor(a.x), math.floor(a.y), a.z or 0)
    if not sq then error("square not loaded (mpWorld first)", 0) end
    inServer(function()
        p:setX(sq:getX() + 0.5); p:setY(sq:getY() + 0.5); p:setZ(sq:getZ())
        p:setCurrent(sq)
        try(function() p:setSquare(sq) end)
    end)
    return { at = sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ(), player = tostring(p:getUsername()) }
end)

-- census over watched squares (extends 81's mpCensus)
local baseCensus = WB.tools.mpCensus
WB.register("mpCensus", function(a)
    local res = baseCensus(a)
    local out = res.items
    local function walk(c, at, depth)
        if depth > 6 or not c then return end
        local items = c:getItems()
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            out[#out + 1] = { id = it:getID(), type = tostring(it:getFullType()), at = at, world = true,
                              condition = try(function() return it:getCondition() end),
                              uses = try(function() return it:getCurrentUses() end), md = "" }
            local inner = try(function() return it:getItemContainer() end)
            if inner then walk(inner, at .. " > " .. tostring(it:getType()) .. "#" .. it:getID(), depth + 1) end
        end
    end
    inServer(function()
        for _, w in pairs(M.watch) do
            local sq = PZEngine.cell():getGridSquare(w.x, w.y, w.z)
            if sq then
                local here = "ground " .. w.x .. "," .. w.y
                local wobjs = sq:getWorldObjects()
                for i = 0, wobjs:size() - 1 do
                    local it = wobjs:get(i):getItem()
                    if it then
                        out[#out + 1] = { id = it:getID(), type = tostring(it:getFullType()), at = here, world = true,
                                          condition = try(function() return it:getCondition() end), uses = try(function() return it:getCurrentUses() end), md = "" }
                        local inner = try(function() return it:getItemContainer() end)
                        if inner then walk(inner, here .. " > " .. tostring(it:getType()) .. "#" .. it:getID(), 1) end
                    end
                end
                local objs = sq:getObjects()
                for i = 0, objs:size() - 1 do
                    local o = objs:get(i)
                    for ci = 0, (try(function() return o:getContainerCount() end) or 0) - 1 do
                        walk(o:getContainerByIndex(ci), "object " .. i .. "/" .. ci .. " @" .. w.x .. "," .. w.y, 0)
                    end
                end
            end
        end
    end)
    return res
end)
