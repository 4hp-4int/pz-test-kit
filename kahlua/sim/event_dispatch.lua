--[[
    PZ Test Kit — Dual-VM event dispatcher
    =======================================
    Runs in a TARGET endpoint's env when DualVMSim delivers a queued command.
    Inputs (set as globals by the Java dispatcher):
        _pz_sim_event_name  — "OnServerCommand" or "OnClientCommand"
        _pz_sim_mod         — module string
        _pz_sim_cmd         — command string
        _pz_sim_args        — args table

        _pz_sim_source      — sending endpoint index (0=server, 1..N=clients)

    Invokes every listener registered on Events[event_name]._listeners.
    Errors are caught so a misbehaving listener doesn't take down the
    dispatch loop.

    THE TWO EVENTS HAVE DIFFERENT ARITIES -- this used to fire both with three
    arguments, which is right for OnServerCommand and wrong for OnClientCommand:

        OnServerCommand(module, command, args)
        OnClientCommand(module, command, PLAYER, args)

    A server handler written to the real signature therefore received the args
    table as `player` and nil as `args`, so its first `args.foo` read yielded
    nil and it returned early. No error, no failed assertion -- the entire
    client->server half of a mod simply looked inert under the sim, which is
    the most expensive kind of test-harness bug: it makes untested code look
    tested. (Found while trying to cover VorpallySauced's Advanced Trajectory
    bindKill handler, whose whole job is receiving a client command.)
]]

local eventName = _pz_sim_event_name
if not eventName or not Events then return end
local evt = Events[eventName]
if not evt or not evt._listeners then return end

-- Count this as a fire for event-coverage reporting.
_pz_event_coverage = _pz_event_coverage or {}
_pz_event_coverage[eventName] = _pz_event_coverage[eventName] or { registered = 0, fired = 0 }
_pz_event_coverage[eventName].fired = _pz_event_coverage[eventName].fired + 1

--- The IsoPlayer the server should see as the sender of a client command.
---
--- Tests with more than one client can register an explicit map on the server
--- endpoint (`_pz_sim_players[clientIndex] = <player>`) so the server sees the
--- right sender and any targeted reply routes back correctly -- server-side
--- sendServerCommand resolves its target from the player's `_client_index`.
--- With one client the endpoint's own getPlayer() is already that player, so
--- the common case needs no setup.
local function resolveSender(idx)
    if _pz_sim_players and idx and _pz_sim_players[idx] then
        return _pz_sim_players[idx]
    end
    if getPlayer then
        local ok, p = pcall(getPlayer)
        if ok then return p end
    end
    return nil
end

if eventName == "OnClientCommand" then
    local sender = resolveSender(_pz_sim_source)
    for _, fn in ipairs(evt._listeners) do
        local ok, err = pcall(fn, _pz_sim_mod, _pz_sim_cmd, sender, _pz_sim_args)
        if not ok then
            print("[Sim] listener error: " .. tostring(err))
        end
    end
else
    for _, fn in ipairs(evt._listeners) do
        local ok, err = pcall(fn, _pz_sim_mod, _pz_sim_cmd, _pz_sim_args)
        if not ok then
            print("[Sim] listener error: " .. tostring(err))
        end
    end
end
