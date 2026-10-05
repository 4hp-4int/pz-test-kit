--[[
    The live dev loop: edits to the mod land in this running VM.

    Tool:   devReload{lua = {requireName...}, scripts = {ScriptType...}}

    Lua: each changed module is re-required. A plain re-require would leave
    the OLD version's event listeners registered next to the new ones, so
    listeners are attributed per module (Events snapshot before/after each
    require) and the previous set is removed before the module loads again.
    Module-level state is rebuilt by the file itself, as on a game restart;
    state other modules captured from the old version (a local reference to
    a function table) keeps pointing at the old one until those reload too.

    Scripts: PZEngine.reloadScripts (ScriptManager.ReloadScripts, the game's
    debug reload: clear the buckets, re-read every file, post-load passes),
    then the workbench's own script caches are dropped. Entity changes also
    re-register sprite configs and drop cached workstation entities.
]]

local D = WB.dev or { listeners = {}, history = {} }
WB.dev = D

local function snapshot()
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

local function removeListeners(list)
    for _, e in ipairs(list or {}) do
        local evt = Events and rawget(Events, e.event)
        if evt and evt._listeners then
            for i = #evt._listeners, 1, -1 do
                if evt._listeners[i] == e.fn then table.remove(evt._listeners, i) end
            end
        end
    end
end

-- Re-require one module; returns ok, err, listenersAdded. `src` is the file's
-- CURRENT text: the kit's require compiles from _pz_module_sources, a copy
-- taken when the VM booted, so without it a re-require runs the old code.
function D.reloadModule(name, src)
    if src and _pz_module_sources then _pz_module_sources[name] = src end
    removeListeners(D.listeners[name])
    local before = snapshot()
    _pz_package_loaded[name] = nil
    local ok, err = pcall(require, name)
    local added = {}
    for evName, evt in pairs(Events or {}) do
        if type(evt) == "table" and evt._listeners then
            local was = before[evName] or {}
            for _, fn in ipairs(evt._listeners) do
                if not was[fn] then added[#added + 1] = { event = evName, fn = fn } end
            end
        end
    end
    D.listeners[name] = added
    return ok, err, added
end

WB.register("devReload", function(a)
    local out = { lua = {}, scripts = nil, at = os.time and os.time() or nil }
    for _, m in ipairs(a.lua or {}) do
        local ok, err, added = D.reloadModule(m, a.sources and a.sources[m])
        local evs = {}
        for _, e in ipairs(added) do evs[#evs + 1] = e.event end
        out.lua[#out.lua + 1] = { module = m, ok = ok, err = (not ok) and tostring(err) or nil, listeners = evs }
    end
    if a.scripts and #a.scripts > 0 then
        local ms, errs = PZEngine.reloadScripts(table.concat(a.scripts, ","))
        out.scripts = { types = a.scripts, ms = ms, hadErrors = errs }
        if ms == nil then out.scripts.err = tostring(errs) end
        for _, c in ipairs(WB.scriptCaches or {}) do for k in pairs(c) do c[k] = nil end end
        local entity = false
        for _, t in ipairs(a.scripts) do if t == "Entity" or t == "EntityTemplate" then entity = true end end
        if entity and WB.craft then
            if WB.craft.spriteConfigs then PZEngine.initSpriteConfigs() end
            WB.craft.benches = {}
        end
    end
    D.history[#D.history + 1] = out
    while #D.history > 20 do table.remove(D.history, 1) end
    return out
end)
