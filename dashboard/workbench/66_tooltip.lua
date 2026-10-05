--[[
    Item tooltips for a live card: TooltipLib's REAL item providers run
    against the engine item, through TooltipLib's own recording context.

    Tool:   itemTooltip{ref, detail, modules}
            modules: require names of files that call registerProvider (the
            server finds them in the mod + its dependencies)

    TooltipLib._createRecordingContext wraps a context and logs every ctx:add*
    call into a display list -- the same list TooltipLib caches and replays
    for cacheable providers. Here the wrapped context is a sink (draws
    nothing headless), so the display list IS the tooltip's content, in
    order, with each provider's own labels, values, colours and bars.
    Provider gating is TooltipLib's: enabled(item), detailOnly vs the detail
    key, the circuit breaker.
]]

local try = WB.try
local T = WB.tooltip or { loaded = {}, errors = {} }
WB.tooltip = T

-- The mod's translation strings (sent by the server once per VM): getText
-- then resolves the providers' keys the way the game does.
function T.strings(strings)
    if type(strings) ~= "table" then return end
    if Translate and Translate.load then Translate.load(strings); return end
    -- No kit Translate in this context (the mod's config doesn't ask for it):
    -- layer the strings over getText, with PZ's %1..%n substitution.
    T.table = T.table or {}
    for k, v in pairs(strings) do T.table[k] = v end
    if not T.wrapped then
        T.wrapped = true
        local base, baseOrNull = getText, getTextOrNull
        local function fill(str, ...)
            local args = { ... }
            return (str:gsub("%%(%d)", function(n) local v = args[tonumber(n)]; return v ~= nil and tostring(v) or "%" .. n end))
        end
        getText = function(key, ...)
            local str = T.table[key]
            if str then return fill(str, ...) end
            return base and base(key, ...) or key
        end
        getTextOrNull = function(key, ...)
            local str = T.table[key]
            if str then return fill(str, ...) end
            return baseOrNull and baseOrNull(key, ...) or nil
        end
    end
end

local function ensure(modules)
    if not TooltipLib then pcall(require, "TooltipLib/Core") end
    if not TooltipLib then return false end
    if not T.helpersTried then
        T.helpersTried = true
        local okh, eh = pcall(require, "TooltipLib/Helpers")
        if not okh then T.errors["TooltipLib/Helpers"] = tostring(eh) end
    end
    -- Providers commonly register from OnGameStart (VPS does). The game fires
    -- it once when the session begins: do the same, once, after the provider
    -- modules load; listeners added by later loads are fired as they appear.
    for _, m in ipairs(modules or {}) do
        if T.loaded[m] == nil then
            local ok, err = pcall(require, m)
            T.loaded[m] = ok
            if not ok then T.errors[m] = tostring(err) end
        end
    end
    local gs = Events and Events.OnGameStart
    local list = gs and gs._listeners or {}
    for i = (T.gameStartFired or 0) + 1, #list do
        local okg, eg = pcall(list[i])
        if not okg then T.errors["OnGameStart #" .. i] = tostring(eg) end
    end
    T.gameStartFired = #list
    return true
end

-- Display-list values to JSON-safe data (colours stay tables; Java objects
-- such as textures become their names).
local function clean(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == "table" then
        if depth > 3 then return "{...}" end
        local out = {}
        for k, x in pairs(v) do out[k] = clean(x, depth + 1) end
        return out
    elseif t == "userdata" then
        return tostring(try(function() return v:getName() end) or v)
    elseif t == "function" then
        return nil
    end
    return v
end

local function vanillaHeader(it)
    return {
        name = tostring(it:getDisplayName()),
        fullType = tostring(it:getFullType()),
        category = tostring(try(function() return it:getDisplayCategory() end) or ""),
        weight = try(function() return it:getActualWeight() end),
        condition = try(function() return it:getCondition() end),
        conditionMax = try(function() return it:getConditionMax() end),
    }
end

T.ensure = ensure

WB.register("itemTooltip", function(a)
    T.strings(a.strings)
    local it = WB.deref(a.ref)
    if not it then error("item $" .. tostring(a.ref) .. " is gone (VM restarted?) - run all") end
    local out = { header = vanillaHeader(it), providers = {}, detail = a.detail and true or false }
    if not ensure(a.modules) then
        out.unavailable = "TooltipLib is not loaded in this mod's context (add PZ-TooltipLib to pz-test.lua dependencies)"
        return out
    end
    out.version = TooltipLib.VERSION
    local errs = {}
    for m, e in pairs(T.errors) do errs[#errs + 1] = m .. ": " .. e end
    out.loadErrors = errs
    local providers = TooltipLib._getProvidersForTarget and TooltipLib._getProvidersForTarget("item") or {}
    local active, hidden = TooltipLib._evaluateProviders(providers, out.detail, it)
    out.hiddenDetail = hidden or false
    for _, p in ipairs(active or {}) do
        local sink = setmetatable({ item = it, detail = out.detail, surface = "item", helpers = TooltipLib.Helpers },
            { __index = function() return function() end end })
        local proxy, list
        if TooltipLib._createRecordingContext then
            proxy, list = TooltipLib._createRecordingContext(sink)
        else
            -- Same {method, args...} entries TooltipLib's recorder writes.
            list = {}
            proxy = setmetatable({ item = it, detail = out.detail, surface = "item", helpers = TooltipLib.Helpers }, {
                __index = function(_, k)
                    return function(_, ...) list[#list + 1] = { k, ... } end
                end })
        end
        local entry = { id = p.id, priority = p.priority }
        if p.preTooltip then
            local okp, ep = pcall(p.preTooltip, sink)
            if not okp then entry.error = "preTooltip: " .. tostring(ep) end
        end
        if not entry.error then
            local ok, err = pcall(p.callback, proxy)
            if not ok then entry.error = tostring(err) end
        end
        entry.lines = clean(list)
        out.providers[#out.providers + 1] = entry
    end
    out.total = #providers
    return out
end)
