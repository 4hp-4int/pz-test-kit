--[[
    SousVide MP: this VM as one side of a multiplayer session
    (docs/sousvide-mp.md; dashboard/mp.js routes the packets).

    Only active in a role VM (`--role server|client`, _pz_role). The
    single-VM bench never runs mpBoot and is unchanged.

    mpBoot{clients}   boot this side like the game boots it:
        - load every mod Lua file the game would RUN on this side, in the
          game's order: server = shared, server (a dedi only checksums
          client/, LuaManager.LoadDirBase(..., true)); client = shared,
          client, then server at game load (GameLoadingState.java:149)
        - the network globals become packets (below), getPlayer is what that
          side has (a dedi has no local player), isMultiplayer() is true
        - players: the server holds one IsoPlayer per client (onlineID i-1,
          username), each client its own local player with the same identity
        - start events: OnGameBoot, then OnGameStart + OnCreatePlayer on a
          client, OnServerStarted on the server (no OnGameStart on a dedi)
    mpDrain{}         hand the dashboard what this side sent since last time
    mpDeliver{packet} apply a packet that arrived (OnClientCommand on the
                      server with the sender's player; OnServerCommand on a
                      client), payload decoded from the real wire bytes
    mpState{}         role, players, boot report

    Packets (phase 1): clientCommand, serverCommand. Item, ModData and
    timed-action packets are later phases.
]]

local try = WB.try
local M = WB.mp or { outbox = {}, players = {}, booted = false }
WB.mp = M

local function role() return rawget(_G, "_pz_role") end
local function index() return math.floor(tonumber(rawget(_G, "_pz_client_index")) or 0) end

local function where(fn) return (WB.fnWhere and WB.fnWhere(fn)) or tostring(fn) end

-- ── identity ───────────────────────────────────────────────────────────────
local function makePlayer(i, existing)
    local p = existing or PZEngine.newPlayer()
    -- setOnlineID takes a short, which Kahlua cannot pass from Lua.
    local _, err = PZEngine.invokeTyped(p, "setOnlineID", "short", i - 1)
    if err then M.identityError = err end
    try(function() p:setUsername("cook" .. i) end)
    try(function() p:setDisplayName("cook" .. i) end)
    return p
end

local function playerList(list)
    return { size = function() return #list end, get = function(_, i) return list[i + 1] end,
             isEmpty = function() return #list == 0 end, _lua = list }
end

local function byOnlineID(id)
    for _, p in ipairs(M.players) do if try(function() return p:getOnlineID() end) == id then return p end end
end

-- ── the network globals ────────────────────────────────────────────────────
local function encode(args)
    if args == nil then return nil, nil end
    local b64, drops = PZEngine.wireEncode(args)
    local d = {}
    if type(drops) == "table" then for _, x in ipairs(drops) do d[#d + 1] = tostring(x) end end
    return b64, d
end

local function send(kind, module, command, args, target)
    local b64, drops = encode(args)
    M.outbox[#M.outbox + 1] = { kind = kind, module = tostring(module), command = tostring(command),
                                b64 = b64, drops = drops, size = b64 and math.floor(#b64 * 3 / 4) or 0,
                                target = target, dir = kind == "clientCommand" and "up" or "down" }
end

-- Other packet kinds (81_mp_items.lua...) queue through this: fields must
-- carry kind, dir ("up" client->server, "down" server->client) and, for a
-- down packet, target (client index) or nil for every client.
function M.queue(pkt)
    pkt.size = pkt.size or (pkt.b64 and math.floor(#pkt.b64 * 3 / 4) or 0)
    M.outbox[#M.outbox + 1] = pkt
end
M.role, M.index, M.byOnlineID, M.where = role, index, byOnlineID, where
M.handlers = M.handlers or {}
M.installers = M.installers or {}

local function installNetwork()
    if role() == "server" then
        -- sendServerCommand(module, command, args) broadcasts;
        -- sendServerCommand(player, module, command, args) targets one client.
        sendServerCommand = function(a, b, c, d)
            if type(a) == "string" then return send("serverCommand", a, b, c, nil) end
            local id = try(function() return a:getOnlineID() end)
            send("serverCommand", b, c, d, id and (id + 1) or nil)
        end
        sendClientCommand = function() M.warn = "sendClientCommand called on the server (no-op in game)" end
        getOnlinePlayers = function() return playerList(M.players) end
        getPlayerByOnlineID = function(id) return byOnlineID(id) end
        -- A dedicated server has no local player.
        getPlayer = function() return nil end
        getSpecificPlayer = function() return nil end
        getNumActivePlayers = function() return 0 end
    else
        -- sendClientCommand(player, module, command, args) or (module, command, args)
        sendClientCommand = function(a, b, c, d)
            if type(a) == "string" then return send("clientCommand", a, b, c) end
            send("clientCommand", b, c, d)
        end
        sendServerCommand = function() M.warn = "sendServerCommand called on a client (no-op in game)" end
        local me = M.players[1]
        getPlayer = function() return me end
        getSpecificPlayer = function(i) if i == 0 then return me end return nil end
        getOnlinePlayers = function() return playerList({ me }) end
        getPlayerByOnlineID = function(id) if try(function() return me:getOnlineID() end) == id then return me end end
        getNumActivePlayers = function() return 1 end
    end
    isMultiplayer = function() return true end
    -- Server options reach every MP client from the server; the bench has
    -- none. Empty = vanilla's own "no match" path (ISLogSystem.logAction
    -- logs nothing for an action type the option doesn't list).
    if rawget(_G, "getServerOptions") == nil then
        getServerOptions = function() return { getOption = function() return "" end, getBoolean = function() return false end } end
    end
    for _, f in ipairs(M.installers) do f(role()) end
end

-- ── boot ───────────────────────────────────────────────────────────────────
local FOLDERS = { server = { "shared", "server" }, client = { "shared", "client", "server" } }

local function folderOf(path)
    return tostring(path):gsub("\\", "/"):match("/media/lua/(%w+)/")
end

local function fire(name, ...)
    local evt = rawget(Events, name)
    local out = { event = name, listeners = 0, errors = {} }
    if not evt or not evt._listeners then return out end
    local list = {}
    for _, fn in ipairs(evt._listeners) do list[#list + 1] = fn end
    out.listeners = #list
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn, ...)
        if not ok then out.errors[#out.errors + 1] = { where = where(fn), err = tostring(err) } end
    end
    return out
end

WB.register("mpBoot", function(a)
    local r = role()
    if not r then error("not a SousVide MP side (boot the bridge with --role)", 0) end
    if M.booted then return M.report end
    local clients = math.max(1, tonumber(a.clients) or 1)

    -- players first: mod files may read getPlayer() at load
    if r == "server" then
        for i = 1, clients do M.players[i] = makePlayer(i) end
    else
        M.players[1] = makePlayer(index(), WB.craft.setup())
    end
    installNetwork()

    -- A client's UI layer: uiview's UIMock (clean-room ISUIElement, ISPanel,
    -- ISBaseObject... with vanilla signatures) stands in for the Java UI the
    -- headless VM lacks, so the vanilla UI tree (ISContextMenu,
    -- ISInventoryPane, ISTimedActionQueue...) can load on top of it. Vanilla
    -- files defining what it provides are skipped (a.uiSkip).
    local ui = { loaded = {}, failed = nil }
    M.uiSkip = {}
    for _, k in ipairs(a.uiSkip or {}) do M.uiSkip[k] = true end
    for _, f in ipairs(a.ui or {}) do
        if _pz_package_loaded[f.name] == nil then
            local chunk, err = (_pz_compile or loadstring)(f.src, f.name)
            local ok, res = false, err
            if chunk then ok, res = pcall(chunk) end
            if ok then
                _pz_package_loaded[f.name] = res == nil and true or res
                ui.loaded[#ui.loaded + 1] = f.name
            else
                ui.failed = f.name .. ": " .. tostring(res)
                break
            end
        end
    end

    -- require reaches vanilla too, as in game (one Lua namespace): a name
    -- the module index lacks is tried as a vanilla file in a folder this
    -- side runs ("ISUI/ISUIElement" -> client/ISUI/ISUIElement).
    if not M.requireWrapped then
        M.requireWrapped = true
        local base = require
        require = function(name)
            local ok, res = pcall(base, name)
            if ok then return res end
            if not tostring(res):find("not found in module index", 1, true) then error(res, 0) end
            local key = tostring(name):gsub("%.lua$", "")
            if M.uiSkip[key] then return true end   -- provided by the UI layer
            for _, f in ipairs(FOLDERS[r]) do
                local file = f .. "/" .. key
                if _pz_read_file(_pz_install_dir .. "/media/lua/" .. file .. ".lua") then
                    -- it exists: its own failure is the real error
                    WB.vanilla(file)
                    return true
                end
            end
            error(res, 0)
        end
    end

    -- vanilla first, as in game: the classes this side's mod code names
    -- (the dashboard picks them, parents ahead), in the folders it runs
    local vanilla = { loaded = 0, failed = {} }
    for _, f in ipairs(a.vanilla or {}) do
        local ok, err = pcall(WB.vanilla, f)
        if ok then vanilla.loaded = vanilla.loaded + 1 else vanilla.failed[#vanilla.failed + 1] = { file = f, err = tostring(err) } end
    end

    -- every file the game runs on this side, in its order
    local byFolder = {}
    for name, path in pairs(_pz_module_files or {}) do
        local f = folderOf(path)
        local p = tostring(path):gsub("\\", "/")
        if f and not p:find("/Tests/", 1, true) then
            byFolder[f] = byFolder[f] or {}
            table.insert(byFolder[f], { name = name, path = p })
        end
    end
    local loaded, failed, already = 0, {}, 0
    for _, f in ipairs(FOLDERS[r]) do
        local list = byFolder[f] or {}
        table.sort(list, function(x, y) return x.path:lower() < y.path:lower() end)
        for _, m in ipairs(list) do
            if _pz_package_loaded[m.name] ~= nil then
                already = already + 1
            else
                local ok, err = pcall(require, m.name)
                if ok then loaded = loaded + 1 else failed[#failed + 1] = { module = m.name, err = tostring(err) } end
            end
        end
    end

    local events = { fire("OnGameBoot") }
    if r == "server" then
        events[#events + 1] = fire("OnServerStarted")
    else
        events[#events + 1] = fire("OnGameStart")
        events[#events + 1] = fire("OnCreatePlayer", 0, M.players[1])
    end

    M.booted = true
    local names = {}
    for _, p in ipairs(M.players) do names[#names + 1] = tostring(try(function() return p:getUsername() end)) end
    M.report = { role = r, index = index(), folders = FOLDERS[r], vanilla = vanilla, ui = ui, identityError = M.identityError,
                 loaded = loaded, alreadyLoaded = already,
                 failed = failed, events = events, players = names, packets = #M.outbox }
    return M.report
end)

WB.register("mpDrain", function()
    local out = M.outbox
    M.outbox = {}
    local warn = M.warn
    M.warn = nil
    return { packets = out, warn = warn }
end)

-- A command's arguments, for the packet log (the dashboard only has bytes).
local function describe(v, depth)
    depth = depth or 0
    if type(v) ~= "table" then return v end
    if depth > 3 then return "{...}" end
    local o = {}
    for k, x in pairs(v) do o[tostring(k)] = describe(x, depth + 1) end
    return o
end

WB.register("mpDeliver", function(a)
    local p = a.packet or {}
    local args = (p.kind == "clientCommand" or p.kind == "serverCommand") and p.b64 and PZEngine.wireDecode(p.b64) or nil
    local before = #M.outbox
    local res
    if p.kind == "clientCommand" then
        if role() ~= "server" then error("a clientCommand arrived at a client", 0) end
        local from = tonumber((tostring(p.from or ""):match("^c(%d+)$"))) or 1
        local player = M.players[from]
        res = fire("OnClientCommand", p.module, p.command, player, args)
        res.player = player and tostring(try(function() return player:getUsername() end)) or nil
    elseif p.kind == "serverCommand" then
        if role() ~= "client" then error("a serverCommand arrived at the server", 0) end
        res = fire("OnServerCommand", p.module, p.command, args)
    elseif M.handlers[p.kind] then
        res = M.handlers[p.kind](p)
        res.sent = #M.outbox - before
        return res
    else
        error("unknown packet kind " .. tostring(p.kind), 0)
    end
    res.args = describe(args)
    res.sent = #M.outbox - before
    return res
end)

WB.register("mpState", function()
    local names = {}
    for _, p in ipairs(M.players) do names[#names + 1] = tostring(try(function() return p:getUsername() end)) end
    return { role = role(), index = index(), booted = M.booted, players = names, outbox = #M.outbox, report = M.report }
end)
