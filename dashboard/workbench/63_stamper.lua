--[[
    Property stamper: prototype tile-property tweaks live, then export them.

    The SauceTweaks pattern (IncineratorScrap, ScrappableFloors, Jukebox):
    tile properties live in binary .tiles files a mod cannot extend, so a
    tweak stamps them onto the sprites' PropertyContainers at boot -- the
    same calls SpriteConfigManager makes -- and everything that reads them
    (disassembly, pickup, water collection, containers) is untouched vanilla.
    Here the stamp lands in the running engine, so the world-object verbs and
    tooltips react immediately; the export writes the boot-time Lua.

    Tools:  spriteProps{sprite}                     every property + flag
            stampSprite{sprite, set, flags, unset, tileType}
            stampUndo{sprite}                       restore what this VM changed
            stampList{}                             this VM's stamps (for export)

    Shared PropertyContainer: every object using the sprite sees the change.
    A tileType stamp (sprite:setTileType) only affects objects created after
    it -- the class (IsoJukebox, IsoRadio...) is chosen at creation.
]]

local try = WB.try
local S = WB.stamps or { list = {}, order = {} }
WB.stamps = S

local function spriteOf(name)
    local mgr = IsoSpriteManager and IsoSpriteManager.instance
    local spr = mgr and try(function() return mgr:getSprite(name) end)
    if not spr then error("no sprite " .. tostring(name)) end
    return spr
end

local function describe(spr)
    local pc = spr:getProperties()
    local props, flags = {}, {}
    for _, k in ipairs(WB.list(try(function() return pc:getPropertyNames() end))) do
        props[tostring(k)] = tostring(try(function() return pc:get(tostring(k)) end) or "")
    end
    for _, f in ipairs(WB.list(try(function() return pc:getFlagsList() end))) do flags[#flags + 1] = tostring(f) end
    table.sort(flags)
    return { sprite = tostring(spr:getName()), props = props, flags = flags,
             tileType = tostring(try(function() return spr:getTileType() end) or "") }
end

WB.register("spriteProps", function(a) return describe(spriteOf(a.sprite)) end)

WB.register("stampSprite", function(a)
    local spr = spriteOf(a.sprite)
    local pc = spr:getProperties()
    local rec = S.list[a.sprite]
    if not rec then
        rec = { sprite = a.sprite, set = {}, flags = {}, unset = {}, original = {} }
        S.list[a.sprite] = rec
        S.order[#S.order + 1] = a.sprite
    end
    local function remember(k)
        if rec.original[k] == nil then
            local had = try(function() return pc:has(k) end) and true or false
            rec.original[k] = { had = had, value = had and tostring(try(function() return pc:get(k) end) or "") or nil }
        end
    end
    for k, v in pairs(a.set or {}) do
        remember(k)
        if v == "" or v == true then pc:set(k) else pc:set(k, tostring(v)) end
        rec.set[k] = (v == true) and "" or tostring(v)
        rec.unset[k] = nil
    end
    for _, f in ipairs(a.flags or {}) do
        local ft = IsoFlagType and IsoFlagType[f]
        if not ft then error("no IsoFlagType." .. tostring(f)) end
        if rec.original["flag:" .. f] == nil then
            rec.original["flag:" .. f] = { had = try(function() return pc:has(ft) end) and true or false }
        end
        pc:set(ft)
        rec.flags[f] = true
    end
    for _, k in ipairs(a.unset or {}) do
        remember(k)
        pc:unset(k)
        rec.unset[k] = true
        rec.set[k] = nil
    end
    if a.tileType and a.tileType ~= "" then
        local tt = IsoObjectType and IsoObjectType[a.tileType]
        if not tt then error("no IsoObjectType." .. tostring(a.tileType)) end
        if rec.originalTileType == nil then rec.originalTileType = tostring(try(function() return spr:getTileType() end) or "") end
        spr:setTileType(tt)
        rec.tileType = a.tileType
    end
    pc:CreateKeySet()
    return describe(spr)
end)

WB.register("stampUndo", function(a)
    local rec = S.list[a.sprite]
    if not rec then return { restored = false } end
    local spr = spriteOf(a.sprite)
    local pc = spr:getProperties()
    for k, o in pairs(rec.original) do
        local flag = k:match("^flag:(.+)$")
        if flag then
            if not o.had and IsoFlagType and IsoFlagType[flag] then pc:unset(IsoFlagType[flag]) end
        elseif o.had then
            if o.value == "" then pc:set(k) else pc:set(k, o.value) end
        else
            pc:unset(k)
        end
    end
    if rec.originalTileType and rec.originalTileType ~= "" and IsoObjectType and IsoObjectType[rec.originalTileType] then
        spr:setTileType(IsoObjectType[rec.originalTileType])
    end
    pc:CreateKeySet()
    S.list[a.sprite] = nil
    for i, s in ipairs(S.order) do if s == a.sprite then table.remove(S.order, i); break end end
    return { restored = true, now = describe(spr) }
end)

WB.register("stampList", function()
    local out = {}
    for _, s in ipairs(S.order) do
        local r = S.list[s]
        local flags = {}
        for f in pairs(r.flags) do flags[#flags + 1] = f end
        local unset = {}
        for k in pairs(r.unset) do unset[#unset + 1] = k end
        out[#out + 1] = { sprite = s, set = r.set, flags = flags, unset = unset, tileType = r.tileType }
    end
    return { stamps = out }
end)

--[[
    stampExport{name, folder, sprites?, guard?: {key, value}, tweak?}
    -> { path, text }: the boot-time Lua that re-applies this VM's stamps in
    game. Same shape as SauceTweaks' IncineratorScrap / Jukebox: stamp once
    sprite data exists (OnGameStart / OnServerStarted, latched), remember what
    each key held, unstamp exactly that. With `tweak` and a manifest table
    (<folder>.implement / .bind, as SauceTweaks has), it gates on the manifest.
    The dashboard's mod-file endpoint writes the text.
]]
local function q(s) return string.format("%q", tostring(s)) end

local function sortedKeys(t)
    local out = {}
    for k in pairs(t or {}) do out[#out + 1] = k end
    table.sort(out)
    return out
end

-- The generated file's body. Fixed text; only the STAMPS table, GUARD and
-- the manifest gate vary.
local BODY = [==[

-- What each stamped sprite held before, so unstamping undoes exactly our work.
local stamped = {}

local function stampAll()
    -- Dedicated servers load no sprite data; nothing to stamp.
    if type(getSprite) ~= "function" then return 0 end
    local n = 0
    for name, st in pairs(STAMPS) do
        local sprite = not stamped[name] and getSprite(name)
        local props = sprite and sprite:getProperties()
        if props and (not GUARD or props:propertyEquals(GUARD[1], GUARD[2])) then
            local before = { keys = {}, flags = {}, tileType = sprite:getTileType() }
            local function save(k)
                if before.keys[k] == nil then before.keys[k] = { had = props:has(k), value = props:get(k) } end
            end
            for _, kv in ipairs(st.set or {}) do
                save(kv[1])
                if kv[2] then props:set(kv[1], kv[2]) else props:set(kv[1]) end
            end
            for _, k in ipairs(st.unset or {}) do save(k); props:unset(k) end
            for _, f in ipairs(st.flags or {}) do
                if not props:has(IsoFlagType[f]) then
                    before.flags[#before.flags + 1] = f
                    props:set(IsoFlagType[f])
                end
            end
            if st.tileType then sprite:setTileType(IsoObjectType[st.tileType]) end
            props:CreateKeySet()
            stamped[name] = before
            n = n + 1
        end
    end
    return n
end

local function unstampAll()
    local n = 0
    for name, before in pairs(stamped) do
        local sprite = getSprite(name)
        local props = sprite and sprite:getProperties()
        if props then
            for k, b in pairs(before.keys) do
                if not b.had then props:unset(k)
                elseif b.value == nil or b.value == "" then props:set(k)
                else props:set(k, b.value) end
            end
            for _, f in ipairs(before.flags) do props:unset(IsoFlagType[f]) end
            if STAMPS[name].tileType and before.tileType then sprite:setTileType(before.tileType) end
            props:CreateKeySet()
            n = n + 1
        end
    end
    stamped = {}
    return n
end

local bound = false

local function bindOnce()
    -- Sprites do not exist at file-scope load time. Both events fire on a
    -- listen-server host, hence the latch.
    if bound then return end
    bound = true
%BIND%
end

Events.OnGameStart.Add(bindOnce)
if Events.OnServerStarted then
    Events.OnServerStarted.Add(bindOnce)
end

return { stamp = stampAll, unstamp = unstampAll }
]==]

WB.register("stampExport", function(a)
    local name = (tostring(a.name or "TileStamps"):gsub("[^%w_]", ""))
    local folder = (tostring(a.folder or ""):gsub("[^%w_]", ""))
    if name == "" or folder == "" then error("name and folder are required") end
    local pick = {}
    for _, s in ipairs(a.sprites or S.order) do if S.list[s] then pick[#pick + 1] = s end end
    if #pick == 0 then error("nothing stamped in this VM yet") end

    local L = {}
    local function add(...) for _, l in ipairs({ ... }) do L[#L + 1] = l end end
    add("-- ============================================================================",
        "-- " .. name .. ": tile property stamps",
        "-- ============================================================================",
        "-- Written by the Engine Workbench property stamper; edit freely.",
        "--",
        "-- Tile properties live in binary .tiles files a mod cannot extend, so these",
        "-- are stamped onto the sprites' PropertyContainers once sprite data exists,",
        "-- with the calls SpriteConfigManager makes. Everything that reads them",
        "-- (disassembly, pickup, containers, water collection) is untouched vanilla.",
        "-- The PropertyContainer is shared: every object using the sprite sees it.",
        "-- tileType picks the object CLASS at cell load, so squares already streamed",
        "-- in keep their objects until they reload.",
        "-- ============================================================================",
        "")
    local M = type(_G[folder]) == "table" and _G[folder]
    local manifest = a.tweak and a.tweak ~= "" and M and M.implement and M.bind and true or false
    if manifest then
        add('require "' .. folder .. '/Manifest"', "",
            "local TWEAK = " .. q(a.tweak),
            "if not " .. folder .. ".implement(TWEAK) then return end", "")
    end
    if a.guard and a.guard.key and a.guard.key ~= "" then
        add("-- Only sprites whose " .. a.guard.key .. " matches are stamped, so a future sheet",
            "-- reshuffle turns this into a no-op instead of stamping some other object.",
            "local GUARD = { " .. q(a.guard.key) .. ", " .. q(a.guard.value or "") .. " }")
    else
        add('local GUARD = nil   -- e.g. { "CustomName", "Incinerator" }: stamp only matching sprites')
    end
    add("", "local STAMPS = {")
    for _, s in ipairs(pick) do
        local r = S.list[s]
        local parts, set, unset, flags = {}, {}, {}, {}
        for _, k in ipairs(sortedKeys(r.set)) do
            local v = r.set[k]
            set[#set + 1] = v == "" and ("{ " .. q(k) .. " }") or ("{ " .. q(k) .. ", " .. q(v) .. " }")
        end
        if #set > 0 then parts[#parts + 1] = "set = { " .. table.concat(set, ", ") .. " }" end
        for _, k in ipairs(sortedKeys(r.unset)) do unset[#unset + 1] = q(k) end
        if #unset > 0 then parts[#parts + 1] = "unset = { " .. table.concat(unset, ", ") .. " }" end
        for _, f in ipairs(sortedKeys(r.flags)) do flags[#flags + 1] = q(f) end
        if #flags > 0 then parts[#parts + 1] = "flags = { " .. table.concat(flags, ", ") .. " }" end
        if r.tileType then parts[#parts + 1] = "tileType = " .. q(r.tileType) end
        add("    [" .. q(s) .. "] = { " .. table.concat(parts, ", ") .. " },")
    end
    add("}")
    local bind
    if manifest then
        bind = "    " .. folder .. ".bind(TWEAK, function(enabled)\n"
            .. "        local ok, n = pcall(enabled and stampAll or unstampAll)\n"
            .. "        if not ok then " .. folder .. ".error(" .. q(name .. ": ") .. " .. tostring(n)) return end\n"
            .. "        if n > 0 then " .. folder .. ".log(" .. q(name .. ": ") .. ' .. (enabled and "stamped " or "restored ") .. n .. " sprites") end\n'
            .. "    end)"
    else
        bind = "    local ok, n = pcall(stampAll)\n"
            .. '    if not ok then print("[' .. name .. '] stamp failed: " .. tostring(n)) end'
    end
    local body = BODY:gsub("%%BIND%%", function() return bind end)
    return { path = "media/lua/shared/" .. folder .. "/" .. name .. ".lua", text = table.concat(L, "\n") .. body,
             sprites = pick, manifest = manifest }
end)
