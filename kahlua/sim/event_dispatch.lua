--[[
    PZ Test Kit — Dual-VM event dispatcher
    =======================================
    Runs in a TARGET endpoint's env when DualVMSim delivers a queued command.
    Inputs (set as globals by the Java dispatcher):
        _pz_sim_event_name  — "OnServerCommand" or "OnClientCommand"
        _pz_sim_mod         — module string
        _pz_sim_cmd         — command string
        _pz_sim_args        — args table

    Invokes every listener registered on Events[event_name]._listeners.
    Errors are caught so a misbehaving listener doesn't take down the
    dispatch loop.
]]

local eventName = _pz_sim_event_name
if not eventName or not Events then return end
local evt = Events[eventName]
if not evt or not evt._listeners then return end

-- Count this as a fire for event-coverage reporting.
_pz_event_coverage = _pz_event_coverage or {}
_pz_event_coverage[eventName] = _pz_event_coverage[eventName] or { registered = 0, fired = 0 }
_pz_event_coverage[eventName].fired = _pz_event_coverage[eventName].fired + 1

for _, fn in ipairs(evt._listeners) do
    local ok, err = pcall(fn, _pz_sim_mod, _pz_sim_cmd, _pz_sim_args)
    if not ok then
        print("[Sim] listener error: " .. tostring(err))
    end
end
