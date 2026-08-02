--[[
    UIView — pal_trough (add animal feed to a feeding trough)
    =========================================================
    Drives the real trough collect() against a stubbed CFeedingTroughSystem.
    Asserts: a food-mode trough -> "Add Animal Feed" (runnable only with feed, the
    vanilla isAnimalFeed+Drainable predicate); a water-mode trough (no container) ->
    no row; linked multi-tile troughs resolve the master and dedupe to ONE row; the
    run queues the vanilla ISInventoryTransferAction INTO the trough's container.
]]

local Assert = PZTestKit.Assert
local SP = require "palette/pal_trough"

local spy = {}

-- a trough lua object; `mode` = "food" (has container) | "water" (no container).
local function trough(mode, linked)
    local cont = (mode == "food") and { _trough = true } or nil
    local sq = { getX = function() return 0 end, getY = function() return 0 end, getZ = function() return 0 end }
    local iso = { getContainer = function() return cont end, getSquare = function() return sq end }
    local t = { getIsoObject = function() return iso end }
    if linked then t.linkedX = linked.x; t.linkedY = linked.y end
    return t
end

local function feedItem()
    return { _type = "Drainable", isAnimalFeed = function() return true end,
             getContainer = function() return "player-inv" end }
end
local function notFeed()
    return { _type = "Food", isAnimalFeed = function() return false end,
             getContainer = function() return "player-inv" end }
end

-- opts.troughs: map "x,y" -> trough lua object; opts.items: inventory
local function collect(opts)
    opts = opts or {}
    spy.queued = 0
    spy.dest = nil
    _G.ISTimedActionQueue = { add = function() spy.queued = spy.queued + 1 end }
    _G.ISInventoryTransferAction = { new = function(_, _, _, _, dest) spy.dest = dest; return {} end }
    _G.CFeedingTroughSystem = { instance = { getLuaObjectOnSquare = function(_, sq)
        return opts.troughs and opts.troughs[sq:getX() .. "," .. sq:getY()]
    end } }
    _G.instanceof = _G.instanceof or function(it, cls) return type(it) == "table" and it._type == cls end
    _G.luautils = _G.luautils or {}; _G.luautils.walkAdj = function() return true end
    local tools = {}
    for _, t in ipairs(opts.items or {}) do tools[#tools + 1] = t end
    local inv = { getFirstEvalRecurse = function(_, pred)
        for _, it in ipairs(tools) do if pred(it) then return it end end
    end }
    local squares = {}
    local function sqAt(x, y)
        local k = x .. "," .. y
        squares[k] = squares[k] or { getX = function() return x end, getY = function() return y end, getZ = function() return 0 end }
        return squares[k]
    end
    _G.getCell = function() return { getGridSquare = function(_, x, y) return sqAt(x, y) end } end
    _G.getSquare = function(x, y) return sqAt(x, y) end
    local p = { _type = "IsoPlayer", getInventory = function() return inv end, getCurrentSquare = function() return sqAt(0, 0) end }
    _G._pz_player = p
    for _, s in ipairs(SP.sources) do if s.id == "trough" then return s.collect(0) end end
end

local function find(cmds, sub) for _, c in ipairs(cmds) do if tostring(c.label):find(sub, 1, true) then return c end end end

local tests = {}

tests["food_trough_with_feed_offers_add"] = function()
    local row = find(collect({ troughs = { ["0,0"] = trough("food") }, items = { feedItem() } }), "Add Animal Feed")
    if not Assert.notNil(row, "a food-mode trough + feed -> Add Animal Feed") then return false end
    if not Assert.isTrue(row.runnable == true, "feed in bag -> runnable") then return false end
    if not Assert.notNil(row.hl, "row highlights the trough") then return false end
    return Assert.equal(row.category, "farm", "farm category")
end

tests["no_feed_greys_the_row"] = function()
    local row = find(collect({ troughs = { ["0,0"] = trough("food") }, items = { notFeed() } }), "Add Animal Feed")
    return Assert.isTrue(row ~= nil and row.runnable == false, "no valid feed -> blocked with reason")
end

tests["water_mode_trough_has_no_feed_row"] = function()
    local cmds = collect({ troughs = { ["0,0"] = trough("water") }, items = { feedItem() } })
    return Assert.isNil(find(cmds, "Add Animal Feed"), "no container (water mode) -> vanilla can't add feed, neither do we")
end

tests["run_transfers_into_the_trough_container"] = function()
    local row = find(collect({ troughs = { ["0,0"] = trough("food") }, items = { feedItem() } }), "Add Animal Feed")
    row.run()
    if not Assert.equal(spy.queued, 1, "running queues the vanilla transfer") then return false end
    return Assert.isTrue(spy.dest ~= nil and spy.dest._trough == true, "destination is the trough's own container")
end

tests["linked_tiles_dedupe_to_one_row"] = function()
    -- two tiles of ONE multi-tile trough: tile (0,0) links to the master at (1,1)
    -- (the linked hop gates on linkedX/Y > 0, mirroring vanilla's "0 = unset")
    local master = trough("food")
    local slave  = trough("food", { x = 1, y = 1 })
    local cmds = collect({ troughs = { ["1,1"] = master, ["0,0"] = slave }, items = { feedItem() } })
    local n = 0
    for _, c in ipairs(cmds) do if tostring(c.label):find("Add Animal Feed", 1, true) then n = n + 1 end end
    return Assert.equal(n, 1, "master resolution dedupes the multi-tile trough to one row")
end

tests["no_trough_no_rows"] = function()
    return Assert.equal(#collect({ items = { feedItem() } }), 0, "no trough nearby -> no rows")
end

return tests
