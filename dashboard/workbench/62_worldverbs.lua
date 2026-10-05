--[[
    World-object verbs: what you can DO to a thing on a real map square,
    through vanilla's own code paths (and any addon's).

    Tools:  worldVerbs{ref}                    verbs that apply to this object
            worldVerb{ref, verb, params}       run one; reports items made/taken

    Verb shape (core list below; addons add theirs with `worldVerbs = {...}`):
        { id, label, doc, applies = function(obj, sq) -> bool,
          run = function(obj, sq, ctx) -> message, items? }
    ctx.player stands on the object's square (vanilla checks distance and
    standing square); ctx.items(list) reports created/taken items so the
    board can add them as cards.

    Vanilla Lua is loaded on demand with WB.vanilla(file), which also gives
    addons a say: an addon's afterVanilla(file) runs after each load (e.g.
    SauceTweaks re-applies MoveableFluidWeight's wrapper on the real
    ISMoveableSpriteProps, since its unit-test config installs a stand-in).
]]

local try = WB.try

-- getCore() is nil headless. Vanilla files call it at load time; the
-- methods they read get real defaults here. Anything else is LOGGED by name
-- (and answers nil) so a gap shows up instead of silently misbehaving.
if not getCore then
    local function color(r, g, b, a)
        return { r = r, g = g, b = b, a = a, getR = function() return r end, getG = function() return g end,
                 getB = function() return b end, getA = function() return a end }
    end
    local known = {
        getGoodHighlitedColor = function() return color(0.2, 1, 0.2, 1) end,
        getBadHighlitedColor = function() return color(1, 0.2, 0.2, 1) end,
        getGameMode = function() return "Sandbox" end,
        isDedicated = function() return false end,
        getDebug = function() return false end,
        getOptionFontSize = function() return 1 end,
        getScreenWidth = function() return 1920 end,
        getScreenHeight = function() return 1080 end,
    }
    WB.coreMisses = {}
    local core = setmetatable({}, { __index = function(_, k)
        if known[k] then return function(_, ...) return known[k](...) end end
        return function() WB.coreMisses[k] = (WB.coreMisses[k] or 0) + 1; return nil end
    end })
    getCore = function() return core end
end

-- Vanilla Lua creates items with the global instanceItem(); in this VM that
-- is the kit's mock, which knows no real types (a moveable's Mov_* item came
-- back nil, so pick-up silently did nothing). The workbench IS the real
-- engine: the engine's factory first, the mock only for what it refuses.
if PZEngine and PZEngine.instanceItem and not WB.realInstanceItem then
    local mock = instanceItem
    WB.realInstanceItem = true
    instanceItem = function(t, ...)
        local ok, it = pcall(PZEngine.instanceItem, t)
        if ok and it then return it end
        return mock and mock(t, ...) or nil
    end
end

-- Java globals vanilla Lua calls that this VM lacks (LuaManager.GlobalObject).
-- copyTable: deep copy, the one- and two-argument forms (LuaManager.java:1589).
if not copyTable then
    function copyTable(to, from)
        if from == nil then from, to = to, nil end
        local out = to or {}
        if to then for k in pairs(to) do to[k] = nil end end
        for k, v in pairs(from or {}) do out[k] = type(v) == "table" and copyTable(v) or v end
        return out
    end
end
-- The item sends only broadcast to connected clients (LuaManager.java:10336):
-- the harness is a server with none.
if not sendAddItemToContainer then function sendAddItemToContainer() end end
if not sendRemoveItemFromContainer then function sendRemoveItemFromContainer() end end

WB.vanillaLoaded = WB.vanillaLoaded or {}
function WB.vanilla(file)
    if WB.vanillaLoaded[file] then return true end
    local ok, err = PZEngine.loadVanilla(file)
    if not ok then error("vanilla " .. file .. ": " .. tostring(err), 0) end
    WB.vanillaLoaded[file] = true
    for _, id in ipairs(WB.addonOrder or {}) do
        local a = WB.addons[id]
        if a and not a.disabled and a.afterVanilla then
            local okh, eh = pcall(a.afterVanilla, file)
            if not okh then print("[workbench] " .. id .. ".afterVanilla(" .. file .. "): " .. tostring(eh)) end
        end
    end
    return true
end

local function moveables()
    WB.vanilla("shared/Moveables/ISMoveableDefinitions")
    WB.vanilla("shared/Moveables/ISMoveableSpriteProps")
    WB.vanilla("shared/Moveables/ISMoveableTools")
    return ISMoveableSpriteProps
end

local function asServer(fn)
    local prev = PZEngine.setServer and PZEngine.setServer(true)
    local ok, a, b = pcall(fn)
    if PZEngine.setServer then PZEngine.setServer(prev) end
    if not ok then error(a, 0) end
    return a, b
end

-- The craft player, moved onto the object's square.
local function standOn(sq)
    local p = WB.craft and WB.craft.setup and WB.craft.setup()
    if not p then error("no player (engine unavailable?)") end
    p:setCurrent(sq)
    p:setX(sq:getX() + 0.5); p:setY(sq:getY() + 0.5); p:setZ(sq:getZ())
    pcall(function() p:setSquare(sq) end)
    return p
end

WB.standOn = standOn

local function inventoryDiff(inv, fn)
    local before = {}
    for _, it in ipairs(WB.list(inv:getItems())) do before[it] = true end
    local r1, r2 = fn()
    local added = {}
    for _, it in ipairs(WB.list(inv:getItems())) do if not before[it] then added[#added + 1] = it end end
    return added, r1, r2
end

WB.worldVerbsCore = {
    {
        id = "contents", label = "Take out the contents",
        doc = "Each item in this object's containers becomes a live item card (the items stay where they are)",
        applies = function(o) return (try(function() return o:getContainerCount() end) or 0) > 0 end,
        run = function(o, _, ctx)
            local items = {}
            for i = 0, o:getContainerCount() - 1 do
                for _, it in ipairs(WB.list(o:getContainerByIndex(i):getItems())) do items[#items + 1] = it end
            end
            ctx.items(items)
            return #items .. " item(s)" .. (#items == 0 and " (map containers are empty until loot is rolled)" or "")
        end,
    },
    {
        id = "pickup", label = "Pick up (moveable)",
        doc = "Vanilla ISMoveableSpriteProps: canPickUpMoveable, then pickUpMoveable. Refusals come from the real checks (fluid inside, skills, tools, weight)",
        applies = function(o)
            local spr = try(function() return o:getSprite() end)
            local props = spr and try(function() return spr:getProperties() end)
            return props and try(function() return props:has("IsMoveAble") end) or false
        end,
        run = function(o, sq, ctx)
            local MSP = moveables()
            local mp = MSP.fromObject(o)
            if not mp then return "not a moveable (ISMoveableSpriteProps.fromObject gave nil)" end
            local can = mp:canPickUpMoveable(ctx.player, sq, o)
            if not can then
                local why = {}
                if try(function() return o:hasFluid() end) then why[#why + 1] = "it holds fluid" end
                if not try(function() return o:isObjectNoContainerOrEmpty() end) then why[#why + 1] = "its container is not empty" end
                return "REFUSED by canPickUpMoveable" .. (#why > 0 and (": " .. table.concat(why, ", ")) or ""), "refused"
            end
            local added = inventoryDiff(ctx.player:getInventory(), function() mp:pickUpMoveable(ctx.player, sq, true) end)
            ctx.items(added)
            local gone = not sq:getObjects():contains(o)
            if #added == 0 and gone then
                return "it BROKE while being picked up: vanilla doBreakTest (a skill-based break chance; the workbench player has no skills) left debris, no item", "changed"
            end
            return "picked up: " .. #added .. " item(s)", "changed"
        end,
    },
    {
        id = "scrap", label = "Disassemble (scrap)",
        doc = "Vanilla ISMoveableSpriteProps: canScrapObject, then scrapObject. Tools are in the player's inventory first (hammer, screwdriver, saw, blowtorch + mask)",
        applies = function(o)
            local spr = try(function() return o:getSprite() end)
            local props = spr and try(function() return spr:getProperties() end)
            return props and (try(function() return props:has("CanScrap") end) or try(function() return props:has("IsMoveAble") end)) or false
        end,
        params = { { name = "giveTools", type = "bool", default = true } },
        run = function(o, sq, ctx, p)
            local MSP = moveables()
            local mp = MSP.fromObject(o)
            if not mp then return "not scrappable (fromObject gave nil)" end
            if p.giveTools ~= false then
                for _, t in ipairs({ "Base.Hammer", "Base.Screwdriver", "Base.Saw", "Base.BlowTorch", "Base.WeldingMask", "Base.Wrench" }) do
                    if not ctx.player:getInventory():containsTypeRecurse(t:gsub("^Base%.", "")) then ctx.player:getInventory():AddItem(t) end
                end
            end
            local can = mp:canScrapObject(ctx.player)
            if type(can) == "table" then can = can.canScrap end
            if not can then return "REFUSED by canScrapObject", "refused" end
            local added = inventoryDiff(ctx.player:getInventory(), function() mp:scrapObject(ctx.player) end)
            ctx.items(added)
            return "scrapped: " .. #added .. " item(s)", "changed"
        end,
    },
    {
        id = "door", label = "Open / close",
        doc = "IsoDoor / IsoThumpable door:ToggleDoor(player)",
        applies = function(o) return instanceof(o, "IsoDoor") or (instanceof(o, "IsoThumpable") and try(function() return o:isDoor() end)) end,
        run = function(o, _, ctx)
            o:ToggleDoor(ctx.player)
            return "door is now " .. (o:IsOpen() and "open" or "closed"), "changed"
        end,
    },
    {
        id = "light", label = "Toggle light",
        doc = "IsoLightSwitch:toggle() (needs power to light, as in game)",
        applies = function(o) return instanceof(o, "IsoLightSwitch") end,
        run = function(o)
            o:toggle()
            return "switch is now " .. (o:isActivated() and "on" or "off"), "changed"
        end,
    },
}

local function verbList()
    local list = {}
    for _, v in ipairs(WB.worldVerbsCore) do list[#list + 1] = { v = v, addon = "core" } end
    for _, id in ipairs(WB.addonOrder or {}) do
        local a = WB.addons[id]
        if a and not a.disabled and a.worldVerbs then
            for _, v in ipairs(a.worldVerbs) do list[#list + 1] = { v = v, addon = id } end
        end
    end
    return list
end

WB.register("worldVerbs", function(a)
    local o = WB.deref(a.ref)
    if not o then error("object $" .. tostring(a.ref) .. " is gone (VM restarted?) - reload the square") end
    local sq = try(function() return o:getSquare() end)
    local out = {}
    for _, e in ipairs(verbList()) do
        local ok, yes = pcall(e.v.applies or function() return true end, o, sq)
        if ok and yes then out[#out + 1] = { id = e.v.id, addon = e.addon, label = e.v.label or e.v.id, doc = e.v.doc, params = e.v.params } end
    end
    return { verbs = out }
end)

WB.register("worldVerb", function(a)
    local o = WB.deref(a.ref)
    if not o then error("object $" .. tostring(a.ref) .. " is gone (VM restarted?) - reload the square") end
    local verb
    for _, e in ipairs(verbList()) do if e.v.id == a.verb and (not a.addon or a.addon == e.addon) then verb = e.v end end
    if not verb then error("no world verb " .. tostring(a.verb)) end
    local params = {}
    for _, pd in ipairs(verb.params or {}) do params[pd.name] = pd.default end
    for k, v in pairs(a.params or {}) do params[k] = v end
    local items, log = {}, {}
    return asServer(function()
        local sq = o:getSquare()
        local ctx = { player = standOn(sq), items = function(list) for _, it in ipairs(list or {}) do items[#items + 1] = it end end,
                      log = function(m) log[#log + 1] = tostring(m) end }
        local msg, state = verb.run(o, sq, ctx, params)
        local snaps = {}
        for _, it in ipairs(items) do
            snaps[#snaps + 1] = { ref = WB.ref(it), fullType = tostring(it:getFullType()), name = tostring(it:getDisplayName()) }
        end
        return { ok = state ~= "refused", state = state or "ran", msg = tostring(msg), items = snaps, log = log,
                 coreMisses = WB.coreMisses }
    end)
end)
