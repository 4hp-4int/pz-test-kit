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
    -- getCell(): the REAL cell, not the kit's mock. Square lookups answer
    -- from the loaded world (ServerMap) only under GameServer.server, so a
    -- client side's view sets it around the call.
    -- (looked up per call: the world loads after boot, via mpWorld)
    local mockCell = getCell
    local view = setmetatable({}, { __index = function(_, k)
        return function(_, ...)
            local realCell = PZEngine.cell and PZEngine.cell()
            local prev = PZEngine.setServer(true)
            local res = { pcall(realCell[k], realCell, ...) }
            PZEngine.setServer(prev)
            if not res[1] then error(res[2], 0) end
            return unpack(res, 2)
        end
    end })
    getCell = function()
        if PZEngine.cell and PZEngine.cell() then return view end
        return mockCell and mockCell()
    end
    -- LuaEventManager.AddEvent: the Java registrar vanilla and mods call
    -- for custom events (Vehicles.lua: OnUseVehicle, OnVehicleHorn).
    -- Registering = the event exists for Events.X.Add / triggerEvent.
    if rawget(_G, "LuaEventManager") == nil then
        LuaEventManager = { AddEvent = function(name) local _ = Events[name] end }
    end
    -- Hook: the game's hook tables (LuaHookManager.AddEvents :123-130), same
    -- Add/Remove shape as Events; any other name is created on first use.
    if rawget(_G, "Hook") == nil or getmetatable(Hook) == nil then
        local H = rawget(_G, "Hook") or {}
        setmetatable(H, { __index = function(t, k)
            local h = { _listeners = {}, _name = k }
            h.Add = function(fn) table.insert(h._listeners, fn) end
            h.Remove = function(fn) for i = #h._listeners, 1, -1 do if h._listeners[i] == fn then table.remove(h._listeners, i) end end end
            rawset(t, k, h)
            return h
        end })
        for _, k in ipairs({ "AutoDrink", "UseItem", "Attack", "CalculateStats", "ContextualAction", "WeaponHitCharacter", "WeaponSwing", "WeaponSwingHitPoint" }) do local _ = H[k] end
        Hook = H
    end
    if role() == "client" then
        -- the player's screen rect (split-screen layout; one player, whole screen)
        local sw = function() return getCore():getScreenWidth() end
        local shh = function() return getCore():getScreenHeight() end
        getPlayerScreenLeft = function() return 0 end
        getPlayerScreenTop = function() return 0 end
        getPlayerScreenWidth = function() return sw() end
        getPlayerScreenHeight = function() return shh() end
    end
    -- getSandboxOptions():initSandboxVars(): vanilla SandboxVars.lua resets
    -- SandboxVars to the Apocalypse preset, then this call adds every MOD
    -- option back. Here: the kit's sandbox (mod defaults from pz-test.lua /
    -- sandbox-options.txt) merged in, then the engine's defaults for gaps.
    M.kitSandbox = M.kitSandbox or SandboxVars
    if rawget(_G, "getSandboxOptions") == nil then
        local function merge(dst, src)
            for k, v in pairs(src or {}) do
                if dst[k] == nil then dst[k] = v
                elseif type(dst[k]) == "table" and type(v) == "table" then merge(dst[k], v) end
            end
        end
        local so = SandboxOptions and SandboxOptions.instance
        getSandboxOptions = function()
            return setmetatable({ initSandboxVars = function()
                if type(SandboxVars) ~= "table" then SandboxVars = {} end
                if M.kitSandbox ~= SandboxVars then merge(SandboxVars, M.kitSandbox) end
                if WB.fillSandboxDefaults then pcall(WB.fillSandboxDefaults) end
            end }, { __index = function(_, k)
                local v = so and so[k]
                if type(v) == "function" then return function(_, ...) return v(so, ...) end end
                return v
            end })
        end
    end
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

-- Run a vanilla file the way the game's require/LoadDirBase does: once,
-- returning the chunk's value (SandboxVars = require "Sandbox/Apocalypse"
-- needs the table, not `true`), with the folder it lives in on the stack:
-- while a shared/ file runs, only shared/ is on the search path (the
-- game's shared pass), so its requires and class reads cannot reach client
-- files that have not loaded yet.
local RANK = { shared = 1, client = 2, server = 3 }
M.vanillaValues = M.vanillaValues or {}
M.folderStack = M.folderStack or {}
function M.runVanilla(file)
    if WB.vanillaLoaded[file] then return M.vanillaValues[file] end
    local src = _pz_read_file(_pz_install_dir .. "/media/lua/" .. file .. ".lua")
    if not src then error("no vanilla file " .. file, 0) end
    local chunk, err = (_pz_compile or loadstring)(src, "vanilla:" .. file)
    if not chunk then error("vanilla " .. file .. ": " .. tostring(err), 0) end
    WB.vanillaLoaded[file] = true   -- before running: a require cycle sees it loaded, as in game
    table.insert(M.folderStack, file:match("^(%w+)/"))
    local res = { pcall(chunk) }
    table.remove(M.folderStack)
    if not res[1] then error("vanilla " .. file .. ": " .. tostring(res[2]), 0) end
    M.vanillaValues[file] = res[2]
    for _, id in ipairs(WB.addonOrder or {}) do
        local ad = WB.addons[id]
        if ad and not ad.disabled and ad.afterVanilla then pcall(ad.afterVanilla, file) end
    end
    return res[2]
end
-- folders reachable right now: up to the running vanilla file's folder
function M.reachable(r)
    local top = M.folderStack[#M.folderStack]
    local base = M.full and M.openFolders or FOLDERS[r]
    if not top then return base end
    local out = {}
    for _, f in ipairs(base) do if (RANK[f] or 9) <= (RANK[top] or 9) then out[#out + 1] = f end end
    return out
end

WB.register("mpBoot", function(a)
    local r = role()
    if not r then error("not a SousVide MP side (boot the bridge with --role)", 0) end
    if M.booted then return M.report end
    local clients = math.max(1, tonumber(a.clients) or 1)

    -- The entity system, as the game starts it before any player acts:
    -- without it setPrimaryHandItem silently does nothing (the Arena found
    -- this first), so on an MP side a held weapon was never held -- a
    -- server-side equip, a death holding a weapon, anything reading the hands.
    if PZEngine.initEntities then pcall(PZEngine.initEntities) end

    -- players first: mod files may read getPlayer() at load
    if r == "server" then
        for i = 1, clients do M.players[i] = makePlayer(i) end
    else
        M.players[1] = makePlayer(index(), WB.craft.setup())
        -- the client's own player is LOCAL, as in game (IsoPlayer.players[0]):
        -- isLocalPlayer() reads that array, and mods gate observer events on it
        if PZEngine.setLocalPlayer then pcall(PZEngine.setLocalPlayer, M.players[1], 0) end
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

    -- getCore():isDedicated() -- true only on the server (a dedi). After the
    -- UI layer, which installs its own getCore.
    do
        local baseCore = getCore
        local dedicated = r == "server"
        getCore = function()
            local c = baseCore and baseCore()
            return setmetatable({ isDedicated = function() return dedicated end }, { __index = function(_, k)
                local v = c and c[k]
                if type(v) == "function" then return function(_, ...) return v(c, ...) end end
                return v
            end })
        end
    end

    -- require reaches vanilla too, as in game (one Lua namespace): a name
    -- the module index lacks is tried as a vanilla file in a folder this
    -- side runs ("ISUI/ISUIElement" -> client/ISUI/ISUIElement).
    -- The game's require (LuaManager.require) only tries media/lua/<folder>/
    -- <name>.lua for each loaded folder; a miss warns and returns nil. It
    -- rarely matters there because EVERY vanilla file has already run. Here
    -- only what is needed runs, so a miss falls back to the vanilla file of
    -- that name anywhere in this side's folders (client/Vehicles/ISUI/
    -- ISVehicleMenu for "ISUI/ISVehicleMenu"), then to the game's nil.
    M.vanillaBySuffix = {}
    for _, f in ipairs(a.vanillaFiles or {}) do
        local tail = f:match("^[^/]+/(.*)$")
        while tail do
            if M.vanillaBySuffix[tail] == nil then M.vanillaBySuffix[tail] = f end
            tail = tail:match("^[^/]+/(.*)$")
        end
    end
    M.requireMisses = {}
    if not M.requireWrapped then
        M.requireWrapped = true
        local base = require
        require = function(name)
            local ok, res = pcall(base, name)
            if ok then return res end
            if not tostring(res):find("not found in module index", 1, true) then error(res, 0) end
            local key = tostring(name):gsub("%.lua$", ""):gsub("\\", "/")
            if M.uiSkip[key] then return true end   -- provided by the UI layer
            -- full mode: the game's search path is the folders loaded SO FAR
            -- (LuaManager.paths grows per LoadDirBase); a shared file cannot
            -- require a client file during the shared pass
            for _, f in ipairs(M.reachable(r)) do
                local file = f .. "/" .. key
                if WB.vanillaLoaded[file] then return M.vanillaValues[file] end
                if _pz_read_file(_pz_install_dir .. "/media/lua/" .. file .. ".lua") then
                    -- it exists: its own failure is the real error
                    return M.runVanilla(file)
                end
            end
            local any = not M.full and #M.folderStack == 0 and M.vanillaBySuffix[key]
            if any then return M.runVanilla(any) end
            M.requireMisses[#M.requireMisses + 1] = key
            return nil   -- the game: DebugType.Lua.warn("require(...) failed"), nil
        end
    end

    -- In game EVERY vanilla file has run before anything reads a class;
    -- here a global read of a vanilla class that isn't loaded yet loads its
    -- file then (a.classes: class -> file, from the dashboard's index).
    M.full = a.full and true or false
    M.openFolders = {}
    M.classes = M.full and {} or (a.classes or {})   -- full mode loads them all, in order
    M.autoloaded, M.autoloadFailed = {}, {}
    if not M.autoloadInstalled then
        M.autoloadInstalled = true
        local loading = {}
        local mt = getmetatable(_G) or {}
        local prior = mt.__index
        mt.__index = function(t, k)
            local file = type(k) == "string" and M.classes[k]
            local top = M.folderStack[#M.folderStack]
            if file and top and (RANK[file:match("^(%w+)/")] or 9) > (RANK[top] or 9) then file = nil end
            if file and not loading[k] and not M.autoloadFailed[k] then
                loading[k] = true
                local ok, err = pcall(M.runVanilla, file)
                loading[k] = nil
                if ok then M.autoloaded[#M.autoloaded + 1] = k else M.autoloadFailed[k] = tostring(err) end
                local v = rawget(t, k)
                if v ~= nil then return v end
            end
            if type(prior) == "function" then return prior(t, k) end
            if type(prior) == "table" then return prior[k] end
            return nil
        end
        setmetatable(_G, mt)
    end

    -- vanilla first, as in game: the classes this side's mod code names
    -- (the dashboard picks them, parents ahead), in the folders it runs
    local vanilla = { loaded = 0, failed = {} }
    for _, f in ipairs(a.vanilla or {}) do
        local ok, err = pcall(M.runVanilla, f)
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
    local full = { folders = {}, failed = {}, failedCount = 0 }
    for _, f in ipairs(FOLDERS[r]) do
        M.openFolders[#M.openFolders + 1] = f
        local list = {}
        for _, m in ipairs(byFolder[f] or {}) do
            local rel = (m.path:match("/media/lua/" .. f .. "/(.*)%.lua$") or m.path):lower()
            list[#list + 1] = { mod = m, key = rel }
        end
        if M.full then
            -- LoadDirBase(f): vanilla and mod files of the folder together,
            -- by path; a mod file at a vanilla path replaces it
            local modKeys = {}
            for _, e in ipairs(list) do modKeys[e.key] = true end
            for _, v in ipairs(a.vanillaFiles or {}) do
                local rel = v:match("^" .. f .. "/(.*)$")
                if rel and not modKeys[rel:lower()] and not M.uiSkip[rel] then list[#list + 1] = { vanilla = v, key = rel:lower() } end
            end
        end
        table.sort(list, function(x, y) return x.key < y.key end)
        local fs = { folder = f, vanilla = 0, vanillaFailed = 0, mod = 0 }
        for _, e in ipairs(list) do
            if e.vanilla then
                if not WB.vanillaLoaded[e.vanilla] then
                    local ok, err = pcall(M.runVanilla, e.vanilla)
                    if ok then fs.vanilla = fs.vanilla + 1
                    else
                        fs.vanillaFailed = fs.vanillaFailed + 1
                        full.failedCount = full.failedCount + 1
                        if #full.failed < 60 then full.failed[#full.failed + 1] = { file = e.vanilla, err = tostring(err) } end
                    end
                end
            elseif _pz_package_loaded[e.mod.name] ~= nil then
                already = already + 1
            else
                local ok, err = pcall(require, e.mod.name)
                if ok then loaded = loaded + 1; fs.mod = fs.mod + 1 else failed[#failed + 1] = { module = e.mod.name, err = tostring(err) } end
            end
        end
        full.folders[#full.folders + 1] = fs
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
                 requireMisses = M.requireMisses, autoloaded = M.autoloaded, autoloadFailed = M.autoloadFailed,
                 full = M.full and full or nil,
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
