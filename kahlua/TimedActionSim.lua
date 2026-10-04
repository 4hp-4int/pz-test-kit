--[[
    PZ Test Kit — Timed-action lifecycle simulator
    ================================================
    Runs a Lua timed action through the hook dispatch PZ ACTUALLY uses,
    per context, so a test cannot invent an MP that does not exist.

    WHY THIS MODULE EXISTS. VorpallySauced v1.13.0 shipped a study action
    whose entire payoff lived in complete(). 1000+ offline tests passed;
    on multiplayer the action recorded nothing, ever, because an MP client
    NEVER executes a Lua action's complete(). No test caught it because
    every test called the hooks the way its author imagined MP works.
    This module is the imagination replaced with the decompile.

    THE DISPATCH RULES (decompiled 42.20 — cite these, do not trust memory):

      IsoGameCharacter.java:9730-9738 — the one finish site:
            act.perform();
            if (!GameClient.client) { act.complete(); }
        So SP runs perform THEN complete on one machine; an MP client runs
        perform ONLY. (LuaTimedActionNew.java:162-168 gates the Lua
        complete call behind !GameClient.client again — double-gated.)

      LuaTimedActionNew.java:77 — an action whose OWN table lacks
        `complete` (rawget; __index does not count) is flagged
        useCustomRemoteTimedActionSync and is NEVER sent to the server.

      NetTimedAction.java:151 — the server rebuilds the action by
        resolving `<Type>.new` as a GLOBAL, then runs serverStart() and,
        when its own timer finishes, complete().

      NetTimedAction.java:42-51 — WHAT is sent is decided by the declared
        parameter NAMES of the class's new(): for each name after self the
        client sends action[name]; the server calls <Type>.new with those
        values in that order. A `function(self, a, b, ...)` wrapper over
        new() therefore sends a and b only and every later argument
        arrives nil (SaucedCarts v2.1.21: "__lt not defined" at
        ISUnequipAction.lua:166, maxTimeInit lost). TA.netRebuild(action)
        replays that round trip.

    WHAT EACH RUNNER RETURNS — a plain report table, for Assert use:
        valid        isValid() result (start/perform still run, so a test
                     can also verify the guard itself)
        performed    perform() was dispatched
        completed    complete() was dispatched
        violations   array of strings; non-empty means the ACTION broke a
                     dispatch law (e.g. something called complete() in the
                     MP-client window). A correct action always reports {}.

    USAGE (the VorpallySauced regression is the reference):

        local TA = PZTestKit.TimedActions

        local shape = TA.shape(MyAction)          -- replication facts
        Assert.isTrue(shape.replicates, "...")

        local r = TA.runClient(MyAction, instance)  -- MP acting client
        Assert.isTrue(r.performed and not r.completed and #r.violations == 0)
        -- ...then assert the BEHAVIOUR still happened (state recorded,
        -- command sent): that is the assertion v1.13.0 was missing.

        local r = TA.runSP(MyAction, instance)      -- both hooks, in order
        local r = TA.runServer(MyAction, serverInstance)  -- refuses if the
        --   class cannot replicate; that refusal IS the test signal.

    Context handling: each runner pins _G.isClient/_G.isServer for its
    window and restores them, so mod-side guards (isClient() gates etc.)
    see the same world the hooks would see in game.
]]

PZTestKit = PZTestKit or {}
PZTestKit.TimedActions = PZTestKit.TimedActions or {}
local TA = PZTestKit.TimedActions

-- ---------------------------------------------------------------------------
-- Shape: the replication facts vanilla derives from the class table itself.
-- ---------------------------------------------------------------------------

--- @param class table the action class (the table :derive() returned)
--- @return table { replicates, ownNew, typeName, typeIsGlobal, problems }
function TA.shape(class)
    local report = { problems = {} }
    if type(class) ~= "table" then
        report.replicates = false
        report.problems[#report.problems + 1] = "not a class table"
        return report
    end

    -- LuaTimedActionNew.java:77 — rawget, deliberately: an INHERITED
    -- complete leaves the action client-only in MP while passing any
    -- `class.complete ~= nil` check.
    report.replicates = rawget(class, "complete") ~= nil
    if not report.replicates then
        report.problems[#report.problems + 1] =
            "no own complete: flagged useCustomRemoteTimedActionSync, never sent to the server"
    end

    -- NetTimedAction.java:151 — the far side rebuilds via <Type>.new.
    report.ownNew = rawget(class, "new") ~= nil
    report.typeName = rawget(class, "Type")
    report.typeIsGlobal = report.typeName ~= nil and _G[report.typeName] == class
    if report.replicates and not report.typeIsGlobal then
        report.problems[#report.problems + 1] =
            "Type is not a global the server can resolve (NetTimedAction.java:151)"
    end

    report.netArgs = TA.netArgs(class)

    return report
end

--- The argument names NetTimedAction.set sends for this class: new()'s
--- declared parameters minus self. nil when new is not a Lua function.
function TA.netArgs(class)
    local params = _pz_closure_params(class and class.new)
    if not params then return nil end
    local names = {}
    for i = 2, #params do names[#names + 1] = params[i] end
    return names
end

-- ---------------------------------------------------------------------------
-- The runners.
-- ---------------------------------------------------------------------------

--- Pin isClient/isServer for a window, restore after — even on error.
local function inContext(client, server, fn, ...)
    local savedClient, savedServer = _G.isClient, _G.isServer
    _G.isClient = function() return client end
    _G.isServer = function() return server end
    local ok, err = pcall(fn, ...)
    _G.isClient = savedClient
    _G.isServer = savedServer
    if not ok then error(err, 0) end
end

--- Replay the MP round trip of a client-built action: collect
--- action[name] for each netArgs name (NetTimedAction.java:42-51), then
--- rebuild it the way the server does, `<Type>.new(<Type>, args...)`
--- (NetTimedAction.java:148-163), under isServer() = true.
--- @return table|nil serverAction, table sent { names, values, n }
function TA.netRebuild(action)
    local class = getmetatable(action)
    local typeName = class and rawget(class, "Type")
    assert(typeName and _G[typeName], "netRebuild: action's Type is not a global")
    local names = TA.netArgs(class) or {}
    local values = {}
    for i, name in ipairs(names) do values[i] = rawget(action, name) end
    local sent = { names = names, values = values, n = #names }
    local serverClass = _G[typeName]
    local rebuilt
    inContext(false, true, function()
        rebuilt = serverClass.new(serverClass, unpack(values, 1, sent.n))
    end)
    return rebuilt, sent
end

--- Wrap class.complete for a window so any dispatch of it is recorded.
--- Restores the original even when the inner run errors.
local function trapComplete(class, report, label, fn)
    local saved = rawget(class, "complete")
    if saved ~= nil then
        class.complete = function(...)
            report.completed = true
            report.violations[#report.violations + 1] =
                "complete() executed " .. label
                .. " -- vanilla never dispatches it there"
                .. " (IsoGameCharacter.java:9733, LuaTimedActionNew.java:165)"
            return saved(...)
        end
    end
    local ok, err = pcall(fn)
    if saved ~= nil then class.complete = saved end
    if not ok then error(err, 0) end
end

--- The common client-side half: isValid gate observed, start if present,
--- then the finish dispatch of IsoGameCharacter.java:9732.
--- opts.skipStart: leave start()/serverStart() undispatched — they are
--- animation/presentation chrome, and a test driving a real action class
--- against fixture items often cannot satisfy their anim surface. The law
--- this module enforces lives at the FINISH site either way.
local function runActingSide(action, report, opts)
    if action.isValid then report.valid = action:isValid() end
    if action.start and not (opts and opts.skipStart) then action:start() end
    if action.perform then
        action:perform()
        report.performed = true
    end
end

--- Single player: perform() THEN complete(), one machine, that order
--- (IsoGameCharacter.java:9732-9735 with GameClient.client false).
--- An action whose payoff double-fires when both hooks run fails HERE.
--- @param class table  the action class (for bookkeeping symmetry)
--- @param action table a constructed instance
function TA.runSP(class, action, opts)
    local report = { violations = {}, performed = false, completed = false }
    inContext(false, false, function()
        runActingSide(action, report, opts)
        if action.complete then
            action:complete()
            report.completed = true
        end
    end)
    return report
end

--- The acting MP client: perform() only. Any complete() dispatch in this
--- window — the engine's, the action's own, anybody's — is a violation.
function TA.runClient(class, action, opts)
    local report = { violations = {}, performed = false, completed = false }
    inContext(true, false, function()
        trapComplete(class, report, "in the MP-client window", function()
            runActingSide(action, report, opts)
        end)
    end)
    return report
end

--- The server half. REFUSES to run a class that vanilla would never send
--- over (no own complete) — report.reached = false is the test signal that
--- an action silently went client-only.
--- The caller supplies the server-side instance: the wire carries
--- constructor state, not your closures, and pretending otherwise here
--- would let a test smuggle client state the real server cannot have.
function TA.runServer(class, serverAction, opts)
    local report = { violations = {}, performed = false, completed = false,
                     reached = false }
    local shape = TA.shape(class)
    if not shape.replicates then
        report.violations[#report.violations + 1] =
            "action never reaches the server: " .. (shape.problems[1] or "?")
        return report
    end
    report.reached = true
    inContext(false, true, function()
        if serverAction.isValid then report.valid = serverAction:isValid() end
        if serverAction.serverStart and not (opts and opts.skipStart) then
            serverAction:serverStart()
        end
        if serverAction.complete then
            serverAction:complete()
            report.completed = true
        end
    end)
    return report
end

--- Both halves of one MP action, in wire order: client acts, then the
--- server (if the class replicates at all) finishes its rebuilt copy.
--- @param makeAction function -> instance; called once per side, because
---        the two machines hold two objects, never one.
function TA.runMP(class, makeAction, opts)
    local report = {
        client = TA.runClient(class, makeAction(), opts),
        shape = TA.shape(class),
    }
    if report.shape.replicates then
        report.server = TA.runServer(class, makeAction(), opts)
    end
    return report
end

return TA
