--[[
    Board actions: timed-action and client-command EMULATION.

    Not everything a player does is a craftRecipe. Inserting a magazine is a
    timed action whose real work happens in an animation event; VPS's
    "Unmake the Stir" and Vorpal Shard rerolls are client -> server commands.
    Addons declare these as `boardActions` (see 40_addons.lua) and run them
    through two helpers that follow PZ's real dispatch:

    WB.runTimed(action, opts)        opts.mode = "sp" | "mp", opts.anims = { {event, param}, ... }
      SP  (IsoGameCharacter.java:9730-9738, one machine runs both halves):
          isValid -> start -> anim events -> perform -> complete
      MP  acting client: isValid -> start -> anim events -> perform (NO complete:
          LuaTimedActionNew.java:162-168 gates it behind !GameClient.client);
          server: a second instance (opts.make) runs serverStart, whose
          emulateAnimEventOnce fires the anim event, then complete.
      Each half runs with isClient/isServer pinned to that side, so the
      mod's and vanilla's own context gates take the branch they take in game.

    WB.clientCommand(player, module, command, args)
      What sendClientCommand does on arrival: every Events.OnClientCommand
      listener runs on the server with (module, command, player, args).
      Server-only modules that returned early in this (client) VM are
      re-required in server context first: WB.serverRequire(name).

    HEADLESS STAND-INS (the only fakes, all scoped to one run):
      action.action        the Java LuaTimedActionNew the action talks to
                           (animations, progress) -> no-op object
      action:forceComplete records that the action asked to finish
      action.netAction     server-side NetTimedAction -> no-op object
      addXp, emulateAnimEventOnce, ISReloadWeaponAction.getReloadTime
                           only if the VM lacks them (it does offline)
      ISTimedActionQueue   perform() reports to the character's queue
                           (onCompleted) and some actions queue a follow-up
                           (ISInsertMagazine racks via addAfter); there is no
                           queue here, so those calls are no-ops for the run
]]

local function noopObject()
    return setmetatable({}, { __index = function() return function() return nil end end })
end

local function withGlobals(tmp, fn)
    local saved = {}
    for k, v in pairs(tmp) do saved[k] = { v = rawget(_G, k) }; if rawget(_G, k) == nil then rawset(_G, k, v) end end
    local res = { pcall(fn) }
    for k, s in pairs(saved) do rawset(_G, k, s.v) end
    if not res[1] then error(res[2], 0) end
    return unpack(res, 2)
end

-- Pins isClient/isServer (and isMultiplayer: true on either MP side) for one
-- side's window, as the real dispatch would see them.
local function inContext(client, server, fn)
    local c, s, m = isClient, isServer, isMultiplayer
    isClient = function() return client end
    isServer = function() return server end
    isMultiplayer = function() return client or server end
    local res = { pcall(fn) }
    isClient, isServer, isMultiplayer = c, s, m
    if not res[1] then error(res[2], 0) end
    return unpack(res, 2)
end

local function prepare(action)
    action.action = action.action or noopObject()
    action.netAction = action.netAction or noopObject()
    action.forceComplete = function(self) self._forced = true end
    return action
end
WB.prepareTimed = prepare   -- MP sides run one half of an action (80_mp.lua)

-- One acting-side pass. Records each hook's outcome; a throwing hook is a
-- finding (shown), not a crash of the tool.
local function actingSide(action, opts, steps, report)
    local function hook(name, fn)
        local ok, e = pcall(fn)
        steps[#steps + 1] = { side = report.side, hook = name, ok = ok, err = (not ok) and tostring(e) or nil }
        return ok
    end
    if action.isValid then hook("isValid", function() report.valid = action:isValid() and true or false end) end
    if action.start then hook("start", function() action:start() end) end
    -- opts.anims entries: { event, param, before = fn(action) }. `before`
    -- stands in for what the animation itself would have done between events
    -- (e.g. a reload loop wrapping, which resets per-loop guards).
    for _, ev in ipairs(opts.anims or {}) do
        if action.animEvent then hook("animEvent " .. tostring(ev[1]), function()
            if ev.before then ev.before(action) end
            action:animEvent(ev[1], ev[2])
        end) end
    end
    if action.perform then hook("perform", function() action:perform() end) end
end

function WB.runTimed(action, opts)
    opts = opts or {}
    local steps, report = {}, { mode = opts.mode or "sp" }
    local stand = {
        addXp = function(chr, perk, xp) pcall(function() chr:getXp():AddXP(perk, xp) end) end,
        ISReloadWeaponAction = { getReloadTime = function() return 1 end },
        -- MP-client action logging reads a server option that doesn't exist
        -- offline; "" = log nothing, vanilla's own no-match branch.
        getServerOptions = function() return { getOption = function() return "" end } end,
        emulateAnimEventOnce = function(net, _, ev, param) if WB._serverAction then WB._serverAction:animEvent(ev, param) end end,
    }
    -- Field-level stand-ins on the mock queue, restored after the run.
    local Q = ISTimedActionQueue
    local qSaved = Q and { get = Q.getTimedActionQueue, add = Q.add, addAfter = Q.addAfter }
    if Q then
        Q.getTimedActionQueue = function() return noopObject() end
        Q.add = function() end
        Q.addAfter = function() end
    end
    local function restoreQueue()
        if Q then Q.getTimedActionQueue, Q.add, Q.addAfter = qSaved.get, qSaved.add, qSaved.addAfter end
    end
    local okRun, errRun = pcall(withGlobals, stand, function()
        if report.mode == "mp" then
            report.side = "client"
            inContext(true, false, function() actingSide(prepare(action), opts, steps, report) end)
            report.clientValid = report.valid
            -- complete() never runs on an MP client; the server rebuilds the action.
            local srv = opts.make and opts.make() or action
            prepare(srv)
            report.side = "server"
            inContext(false, true, function()
                WB._serverAction = srv
                if srv.serverStart then
                    local ok, e = pcall(function() srv:serverStart() end)
                    steps[#steps + 1] = { side = "server", hook = "serverStart", ok = ok, err = (not ok) and tostring(e) or nil }
                end
                if srv.complete then
                    local ok, e = pcall(function() srv:complete() end)
                    steps[#steps + 1] = { side = "server", hook = "complete", ok = ok, err = (not ok) and tostring(e) or nil }
                end
                WB._serverAction = nil
            end)
        else
            report.side = "sp"
            inContext(false, false, function()
                actingSide(prepare(action), opts, steps, report)
                if action.complete then
                    local ok, e = pcall(function() action:complete() end)
                    steps[#steps + 1] = { side = "sp", hook = "complete", ok = ok, err = (not ok) and tostring(e) or nil }
                end
            end)
        end
    end)
    restoreQueue()
    if not okRun then error(errRun, 0) end
    report.side = nil
    report.steps = steps
    report.forced = action._forced or nil
    return report
end

WB.serverLoaded = WB.serverLoaded or {}
-- Loaded once per VM -- but a test run clears event listeners between test
-- cases, so "already loaded" is only true while the listeners that load
-- registered are still in place. Record them; reload when any is gone.
local function listenerSnapshot()
    local s = {}
    for name, evt in pairs(Events or {}) do
        if type(evt) == "table" and evt._listeners then
            local set = {}
            for _, fn in ipairs(evt._listeners) do set[fn] = true end
            s[name] = set
        end
    end
    return s
end
local function stillRegistered(added)
    for _, e in ipairs(added or {}) do
        local evt = Events and rawget(Events, e.event)
        local found = false
        for _, fn in ipairs((evt and evt._listeners) or {}) do if fn == e.fn then found = true; break end end
        if not found then return false end
    end
    return true
end

function WB.serverRequire(name)
    local prev = WB.serverLoaded[name]
    if prev and stillRegistered(prev) then return true end
    local before = listenerSnapshot()
    _pz_package_loaded[name] = nil
    inContext(false, true, function() require(name) end)
    local added = {}
    for evName, evt in pairs(Events or {}) do
        if type(evt) == "table" and evt._listeners then
            local was = before[evName] or {}
            for _, fn in ipairs(evt._listeners) do if not was[fn] then added[#added + 1] = { event = evName, fn = fn } end end
        end
    end
    WB.serverLoaded[name] = added
    return true
end

function WB.clientCommand(player, module, command, args)
    local listeners = {}
    for _, fn in ipairs((Events.OnClientCommand and Events.OnClientCommand._listeners) or {}) do listeners[#listeners + 1] = fn end
    local errs = {}
    inContext(false, true, function()
        for _, fn in ipairs(listeners) do
            local ok, e = pcall(fn, module, command, player, args)
            if not ok then errs[#errs + 1] = tostring(e) end
        end
    end)
    return { listeners = #listeners, errors = errs, module = module, command = command }
end
