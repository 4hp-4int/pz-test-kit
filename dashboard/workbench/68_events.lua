--[[
    Event lab: fire any Lua event at real objects and see what every listener
    did.

    The catalog (dashboard/events-catalog.json, tools/events-catalog.js) lists
    every event the engine registers (LuaEventManager.AddEvent) and every
    place that fires one, Java and vanilla Lua, with each argument's inferred
    type -- so OnHitZombie is offered as (zombie: IsoZombie, wielder:
    IsoGameCharacter, bodyPart: BodyPartType, weapon: HandWeapon).

    Tools:  eventList{q}          catalog + this VM's listeners (counts, where)
            eventInfo{name}       signature, fire sites, listeners by file:line
            eventFire{name, args, context, loadServer?}
              args     one per parameter: {kind = "player" | "zombie" | "item"
                       (ref | type) | "square" (x, y, z) | "object" (ref) |
                       "number" | "string" | "bool" | "nil" | "lua" (expr)}
              context  "sp" | "client" | "server": isClient/isServer pinned for
                       the run, as the listeners' own gates will see them
              loadServer  server context: first load the mod's server-only
                       modules that listen for this event (they returned early
                       in this client VM)

    Each listener runs on its own (pcall), in registration order -- what
    LuaEventManager does -- and the arguments are snapshotted around EACH one,
    so a change is attributed to the listener that made it. Recorded per
    listener: errors, changes (stats, XP, recipes, health, item stats,
    ModData), halos, client/server commands sent, and events it fired in turn.

    HEADLESS STAND-INS (scoped to one fire, restored after): getSpecificPlayer
    / getPlayer (the workbench character), getCell (the real cell), getGameTime
    (the engine's), HaloTextHelper (recorded), addXp (as for a local player).
]]

local try = WB.try
local E = WB.events or {}
WB.events = E

-- ── the catalog ────────────────────────────────────────────────────────────
local function catalog()
    if E.catalog then return E.catalog end
    local path = (_pz_kit_dir or "") .. "/dashboard/events-catalog.json"
    local src = _pz_read_file and _pz_read_file(path)
    if not src then error("no events catalog at " .. path .. " (node dashboard/tools/events-catalog.js)", 0) end
    local c = PZTestKit.Blueprints.decode(src)
    E.catalog, E.byName = c, {}
    for _, e in ipairs(c.events or {}) do E.byName[e.name] = e end
    return c
end

local function listenersOf(name)
    local evt = rawget(Events, name)
    return (evt and evt._listeners) or {}
end

-- PZEngine.fnInfo gives a closure's prototype NAME (the function's own name;
-- nested prototypes carry no filename) and first line. The module is the one
-- whose source has that name on that line.
local lineCache = {}
local function linesOf(mod, src)
    local l = lineCache[mod]
    if l then return l end
    l = {}
    for s in (src .. "\n"):gmatch("([^\n]*)\n") do l[#l + 1] = s end
    lineCache[mod] = l
    return l
end

local function where(fn)
    if not PZEngine.fnInfo then return nil end
    local name, line = PZEngine.fnInfo(fn)
    if not line then return name and tostring(name) or nil end
    line = math.floor(line)
    name = tostring(name or "?")
    local short = name:match("([%w_]+)$") or name
    for mod, src in pairs(_pz_module_sources or {}) do
        if type(src) == "string" then
            -- the first instruction can sit a line or two below the header
            local ls = linesOf(mod, src)
            for d = 0, 3 do
                local s = ls[line - d]
                if s and s:find("function", 1, true) and (short == "?" or s:find(short, 1, true)) then
                    return mod .. ":" .. (line - d) .. (short ~= "?" and (" " .. short) or "")
                end
            end
        end
    end
    return short .. ":" .. line
end

-- Modules whose SOURCE registers for the event (loaded or not): what a
-- server-only module would add if it ran here.
local function registrants(name)
    local out = {}
    local pats = { "Events%." .. name .. "%.Add", 'Events%["' .. name .. '"%]' }
    for mod, src in pairs(_pz_module_sources or {}) do
        if type(src) == "string" then
            for _, p in ipairs(pats) do
                if src:find(p) then
                    -- `if not isServer() then return end` returned early in this
                    -- (client-shaped) VM: its listeners only exist once it runs
                    -- in server context. (`if isClient() then return end` ran.)
                    local early = src:find("if%s+not%s+isServer%(%)%s+then%s+return") ~= nil
                    local viaServer = WB.serverLoaded and WB.serverLoaded[mod] ~= nil
                    out[#out + 1] = { module = mod, serverOnly = early,
                                      loaded = viaServer or (_pz_package_loaded[mod] ~= nil and not early) }
                    break
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.module < b.module end)
    return out
end

WB.register("eventList", function(a)
    local c = catalog()
    local q = a.q and a.q:lower()
    local out, seen = {}, {}
    local function add(name, e)
        if seen[name] then return end
        seen[name] = true
        if q and not name:lower():find(q, 1, true) then return end
        local n = #listenersOf(name)
        out[#out + 1] = { name = name, listeners = n, registered = e and e.registered or false,
                          params = e and e.params or {}, sites = e and (#(e.java or {}) + #(e.lua or {})) or 0,
                          custom = e == nil }
    end
    for _, e in ipairs(c.events) do add(e.name, e) end
    -- events only Lua knows (mods' own, or ones the catalog missed)
    for name, evt in pairs(Events) do
        if type(evt) == "table" and evt._listeners and #evt._listeners > 0 then add(name, E.byName[name]) end
    end
    table.sort(out, function(x, y)
        if (x.listeners > 0) ~= (y.listeners > 0) then return x.listeners > 0 end
        return x.name < y.name
    end)
    return { events = out, count = #out }
end)

WB.register("eventInfo", function(a)
    catalog()
    local e = E.byName[a.name] or { name = a.name, params = {}, java = {}, lua = {} }
    local ls = {}
    for i, fn in ipairs(listenersOf(a.name)) do ls[#ls + 1] = { i = i, where = where(fn) or tostring(fn) } end
    local sites = {}
    for k, s in ipairs(e.java or {}) do
        if k > 12 then break end
        local args = {}
        for _, x in ipairs(s.args or {}) do args[#args + 1] = x.expr end
        sites[#sites + 1] = { where = s.file .. ":" .. s.line, call = a.name .. "(" .. table.concat(args, ", ") .. ")" }
    end
    for k, s in ipairs(e.lua or {}) do
        if k > 6 then break end
        local args = {}
        for _, x in ipairs(s.args or {}) do args[#args + 1] = x.expr end
        sites[#sites + 1] = { where = "lua/" .. s.file .. ":" .. s.line, call = a.name .. "(" .. table.concat(args, ", ") .. ")" }
    end
    return { name = a.name, params = e.params or {}, registered = e.registered, listeners = ls, sites = sites,
             javaSites = #(e.java or {}), luaSites = #(e.lua or {}), registrants = registrants(a.name),
             zombies = PZEngine.newZombie ~= nil }
end)

-- ── arguments ──────────────────────────────────────────────────────────────
local function realSquare(x, y, z)
    local prev = PZEngine.setServer(true)
    local ok, sq = pcall(function() return PZEngine.cell():getGridSquare(x, y, z or 0) end)
    PZEngine.setServer(prev)
    return ok and sq or nil
end

local function buildArg(spec, player)
    local k = spec.kind or "nil"
    if k == "nil" then return nil, "nil" end
    if k == "player" then return player, "the workbench character" end
    if k == "number" then return tonumber(spec.value) or 0, tostring(spec.value) end
    if k == "string" then return tostring(spec.value or ""), string.format("%q", tostring(spec.value or "")) end
    if k == "bool" then return spec.value == true or spec.value == "true", tostring(spec.value) end
    if k == "lua" then
        local f, err = loadstring("return " .. tostring(spec.value))
        if not f then error("lua arg: " .. tostring(err), 0) end
        return f(), tostring(spec.value)
    end
    if k == "item" then
        if spec.ref then
            local it = WB.deref(spec.ref)
            if not it then error("item $" .. tostring(spec.ref) .. " is gone", 0) end
            return it, tostring(it:getFullType()) .. " (board card)"
        end
        local it = PZEngine.instanceItem(spec.type or spec.value)
        if not it then error("no item " .. tostring(spec.type or spec.value), 0) end
        try(function() player:getInventory():AddItem(it) end)
        return it, tostring(it:getFullType()) .. " (fresh)"
    end
    if k == "square" then
        local sq = realSquare(tonumber(spec.x), tonumber(spec.y), tonumber(spec.z) or 0)
        if not sq then error("no square at " .. tostring(spec.x) .. "," .. tostring(spec.y) .. " (load the map there first)", 0) end
        return sq, "square " .. spec.x .. "," .. spec.y .. "," .. (spec.z or 0)
    end
    if k == "object" then
        local o = WB.deref(spec.ref)
        if not o then error("object $" .. tostring(spec.ref) .. " is gone", 0) end
        return o, WB.className(o) .. " (board)"
    end
    if k == "zombie" then
        if spec.ref then return WB.deref(spec.ref), "zombie (kept)" end
        if not PZEngine.newZombie then error("this VM's engine bridge has no newZombie yet: restart the VM once", 0) end
        local sq = player and try(function() return player:getCurrentSquare() end)
        local z, err = PZEngine.newZombie(sq)
        if not z then error("newZombie: " .. tostring(err), 0) end
        E.lastZombie = z
        return z, "a fresh IsoZombie" .. (sq and (" at " .. sq:getX() .. "," .. sq:getY()) or "")
    end
    error("unknown arg kind " .. tostring(k), 0)
end

-- ── observing the arguments ────────────────────────────────────────────────
local STATS = { "BOREDOM", "UNHAPPINESS", "STRESS", "PANIC", "ANGER", "FATIGUE", "ENDURANCE", "HUNGER", "THIRST", "PAIN", "SICKNESS" }
local CHAR = { "getHealth", "isDead", "isOnFire", "isOnFloor", "isKnockedDown", "getHitReaction", "isStaggerBack", "getBumpType" }
local ITEM = { "getName", "getCondition", "getConditionMax", "getHaveBeenRepaired", "getCurrentUses", "getWeight",
               "getMinDamage", "getMaxDamage", "getCriticalChance", "getCritDmgMultiplier", "getBaseSpeed", "getMaxRange",
               "getMinRange", "getKnockbackMod", "getAimingTime", "getRecoilDelay", "getMaxHitCount", "getSoundRadius",
               "getEnduranceMod", "getTreeDamage", "getDoorDamage", "getCriticalDmgMultiplier", "getTooltip" }

local function flatten(t, prefix, out, depth, seen)
    if depth > 5 or seen[t] then return end
    seen[t] = true
    for k, v in pairs(t) do
        local key = prefix .. tostring(k)
        if type(v) == "table" then flatten(v, key .. ".", out, depth + 1, seen) else out[key] = tostring(v) end
    end
end

local function snap(o)
    if o == nil or type(o) ~= "userdata" and type(o) ~= "table" then return nil end
    local s = {}
    local function put(k, v) if v ~= nil and type(v) ~= "userdata" and type(v) ~= "table" then s[k] = v end end
    if instanceof(o, "IsoGameCharacter") then
        for _, m in ipairs(CHAR) do put((m:gsub("^get", "")), try(function() return o[m](o) end)) end
        local st = try(function() return o:getStats() end)
        if st then for _, n in ipairs(STATS) do put("stat." .. n, try(function() return st:get(CharacterStat[n]) end)) end end
        for _, perk in ipairs(WB.list(try(function() return PerkFactory.PerkList end))) do
            local v = try(function() return o:getXp():getXP(perk) end)
            if v and v ~= 0 then put("xp." .. tostring(perk), v) end
        end
        for _, r in ipairs(WB.list(try(function() return o:getKnownRecipes() end))) do s["recipe." .. tostring(r)] = true end
    end
    if instanceof(o, "InventoryItem") then
        for _, m in ipairs(ITEM) do put((m:gsub("^get", "")), try(function() return o[m](o) end)) end
    end
    local md = try(function() return o:getModData() end)
    if type(md) == "table" then
        local f = {}
        flatten(md, "", f, 0, {})
        for k, v in pairs(f) do s["modData." .. k] = v end
    end
    return s
end

local function diff(label, a, b, out)
    if not (a and b) then return end
    for k, v in pairs(b) do
        if a[k] ~= v and not (type(v) == "number" and type(a[k]) == "number" and math.abs(v - a[k]) < 1e-6) then
            out[#out + 1] = { target = label, key = k, from = a[k], to = v }
        end
    end
    for k, v in pairs(a) do if b[k] == nil then out[#out + 1] = { target = label, key = k, from = v } end end
end

local function haloRecorder(sink)
    local color = { r = 1, g = 1, b = 1, getR = function() return 1 end, getG = function() return 1 end, getB = function() return 1 end }
    return setmetatable({}, { __index = function(_, k)
        if type(k) == "string" and k:match("^add") then
            return function(who, text, _, up) sink[#sink + 1] = { text = tostring(text), up = (type(up) == "boolean") and up or nil } end
        end
        return function() return color end
    end })
end

-- ── fire ───────────────────────────────────────────────────────────────────
WB.register("eventFire", function(a)
    catalog()
    local name = a.name
    if not name or name == "" then error("event name required") end
    if WB.tooltip and WB.tooltip.vanilla then WB.tooltip.vanilla() end
    local ctx = a.context or "sp"
    local client, server = ctx == "client", ctx == "server"
    local player = WB.craft.setup()

    local loaded = {}
    if server and a.loadServer then
        for _, r in ipairs(registrants(name)) do
            if r.serverOnly then
                local ok, err = pcall(WB.serverRequire, r.module)
                loaded[#loaded + 1] = { module = r.module, ok = ok, err = (not ok) and tostring(err) or nil }
            end
        end
    end

    local args, labels = {}, {}
    local e = E.byName[name] or { params = {} }
    local n = math.max(#(a.args or {}), #(e.params or {}))
    for i = 1, n do
        local v, label = buildArg((a.args or {})[i] or { kind = "nil" }, player)
        args[i], labels[i] = v, label
    end
    local targets = {}
    for i = 1, n do
        if type(args[i]) == "userdata" then
            local p = e.params and e.params[i]
            targets[#targets + 1] = { i = i, label = (p and p.name or ("arg" .. i)), obj = args[i] }
        end
    end

    -- stand-ins + context
    local saved = { getSpecificPlayer = getSpecificPlayer, getPlayer = getPlayer, getCell = getCell, getGameTime = getGameTime,
                    sendClientCommand = sendClientCommand, sendServerCommand = sendServerCommand, triggerEvent = triggerEvent,
                    isClient = isClient, isServer = isServer, isMultiplayer = isMultiplayer }
    local halos, commands, nested = {}, {}, {}
    local cell, realGT = PZEngine.cell(), PZEngine.gameTime and PZEngine.gameTime()
    local addedGlobals = {}
    getSpecificPlayer = function(i) if i == 0 then return player end return nil end
    getPlayer = function() return player end
    if cell then getCell = function() return cell end end
    if realGT then getGameTime = function() return realGT end end
    for gname, fn in pairs({
        HaloTextHelper = haloRecorder(halos),
        addXp = function(chr, perk, xp) chr:getXp():AddXP(perk, xp, true, true, false) end,
        getRecipeDisplayName = function(r) return tostring(r) end,
    }) do
        if rawget(_G, gname) == nil then rawset(_G, gname, fn); addedGlobals[#addedGlobals + 1] = gname end
    end
    local function rec(kind)
        return function(...)
            local t = { ... }
            local off = (type(t[1]) == "string") and 0 or 1
            commands[#commands + 1] = { kind = kind, module = tostring(t[1 + off]), command = tostring(t[2 + off]) }
            local orig = saved[kind]
            if orig then return orig(...) end
        end
    end
    sendClientCommand, sendServerCommand = rec("sendClientCommand"), rec("sendServerCommand")
    triggerEvent = function(ev, ...)
        nested[#nested + 1] = tostring(ev)
        if saved.triggerEvent then return saved.triggerEvent(ev, ...) end
    end
    isClient = function() return client end
    isServer = function() return server end
    isMultiplayer = function() return client or server end
    local prevServer = PZEngine.setServer(server)

    local results = {}
    local okAll, errAll = pcall(function()
        local list = {}
        for _, fn in ipairs(listenersOf(name)) do list[#list + 1] = fn end
        for i, fn in ipairs(list) do
            local before = {}
            for _, t in ipairs(targets) do before[t.i] = snap(t.obj) end
            local h0, c0, n0 = #halos, #commands, #nested
            local ok, err = pcall(fn, unpack(args, 1, n))
            local changes = {}
            for _, t in ipairs(targets) do diff(t.label, before[t.i], snap(t.obj), changes) end
            local r = { i = i, where = where(fn) or tostring(fn), ok = ok, err = (not ok) and tostring(err) or nil,
                        changes = changes, halos = {}, commands = {}, nested = {} }
            for k = h0 + 1, #halos do r.halos[#r.halos + 1] = halos[k] end
            for k = c0 + 1, #commands do r.commands[#r.commands + 1] = commands[k] end
            for k = n0 + 1, #nested do r.nested[#r.nested + 1] = nested[k] end
            results[#results + 1] = r
        end
    end)

    PZEngine.setServer(prevServer)
    for k, v in pairs(saved) do _G[k] = v end
    for _, gname in ipairs(addedGlobals) do rawset(_G, gname, nil) end
    if not okAll then error(errAll, 0) end

    local refs = {}
    for _, t in ipairs(targets) do refs[#refs + 1] = { label = t.label, ref = WB.ref(t.obj), class = WB.className(t.obj) } end
    return { name = name, context = ctx, args = labels, listeners = results, loaded = loaded, refs = refs,
             registrants = registrants(name) }
end)
