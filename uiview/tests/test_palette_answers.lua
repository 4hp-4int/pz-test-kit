--[[ pal_answers — query-materialized answer rows: recursive inventory counts,
     reach-container holders, room-object locate rows, watch-gated time, the
     filter merge (below real matches), and Enter-cycles-without-closing. ]]
local Assert = PZTestKit.Assert
require "palette/pal_answers"
require "palette/pal_filter"
local States = require "UIView/scenes/PaletteStates"
local D = States.D
local SP = _G.SaucePalette
local A = SP.Answers

local function jlist(t) return { size = function() return #t end, get = function(_, i) return t[i + 1] end } end

local function item(name, inner)
    local it = { getDisplayName = function() return name end,
                 getFullType = function() return "Base." .. name:gsub("%s", "") end }
    if inner then it.getInventory = function() return inner end end
    return it
end
local function containerOf(items) return { getItems = function() return jlist(items) end } end

-- build a full answers harness; opts = { inv, loot = {{type,items,parent}}, room, watch }
local function harness(opts)
    opts = opts or {}
    local saved = { gsp = _G.getSpecificPlayer, gpl = _G.getPlayerLoot,
                    msp = _G.ISMoveableSpriteProps, ggt = _G.getGameTime }
    local center = {
        getX = function() return 0 end, getY = function() return 0 end, getZ = function() return 0 end,
        getRoom = function() return opts.room end,
        getRoomID = function() return opts.room and 7 or -1 end,
    }
    _G.getSpecificPlayer = function()
        return {
            getInventory = function() return containerOf(opts.inv or {}) end,
            getCurrentSquare = function() return center end,
            getWornItem = function() if opts.watch then return item("WristWatch") end return nil end,
        }
    end
    _G.getPlayerLoot = function()
        local backpacks = {}
        for _, l in ipairs(opts.loot or {}) do
            backpacks[#backpacks + 1] = { inventory = {
                getItems = function() return jlist(l.items) end,
                getType = function() return l.type end,
                getParent = function() return l.parent end,
            } }
        end
        return { inventoryPane = { inventoryPage = { backpacks = backpacks } } }
    end
    _G.ISMoveableSpriteProps = { fromObject = function(o) return { name = o and o._name } end }
    _G.getGameTime = function() return { getTimeOfDay = function() return opts.hour or 14.5 end } end
    A._owner, A._index, A._roomCache = nil, nil, nil
    return {
        match = function(q) return A.match(q, 0, harness) end,
        restore = function()
            _G.getSpecificPlayer, _G.getPlayerLoot = saved.gsp, saved.gpl
            _G.ISMoveableSpriteProps, _G.getGameTime = saved.msp, saved.ggt
            A._owner, A._index, A._roomCache = nil, nil, nil
        end,
    }
end

-- room square: a list of named objects at coords
local function roomSquare(x, y, names)
    local objs = {}
    for _, n in ipairs(names) do objs[#objs + 1] = { _type = "IsoObject", _name = n } end
    return { getX = function() return x end, getY = function() return y end, getZ = function() return 0 end,
             getObjects = function() return jlist(objs) end }
end
local function roomOf(sqs) return { getSquares = function() return jlist(sqs) end } end

local function firstRow(rows, pred)
    for _, r in ipairs(rows or {}) do if (not pred) or pred(r.c) then return r.c end end
    return nil
end

local tests = {}

tests["counts_recursive_through_bags"] = function()
    local bag = containerOf({ item("Nails"), item("Nails"), item("Nails") })
    local h = harness({ inv = { item("Nails"), item("Nails"), item("Duffel Bag", bag), item("Hammer") } })
    local rows = h.match("nails")
    local c = firstRow(rows)
    h.restore()
    if not Assert.notNil(c, "an answer row materializes") then return false end
    if not Assert.equal(c.label, "Nails", "named by the item") then return false end
    if not Assert.isTrue(c.source:find("5", 1, true) ~= nil, "total counts through the bag (2+3)") then return false end
    return Assert.isTrue(c.source:find("on you", 1, true) ~= nil, "holder is 'on you'")
end

tests["reach_container_joins_the_count"] = function()
    local crateObj = { _type = "IsoObject", _name = "Crate" }
    local h = harness({
        inv = { item("Nails") },
        loot = { { type = "crate", parent = crateObj,
                   items = { item("Nails"), item("Nails"), item("Nails") } } },
    })
    local rows = h.match("nails")
    local c = firstRow(rows)
    h.restore()
    if not Assert.isTrue(c.source:find("4", 1, true) ~= nil, "total spans you + the crate") then return false end
    if not Assert.isTrue(c.source:find("Crate", 1, true) ~= nil, "the crate is named") then return false end
    return Assert.isTrue(c.hl == crateObj, "highlight starts on the biggest world stash")
end

tests["enter_cycles_the_highlight"] = function()
    local crateObj = { _name = "Crate" }
    local h = harness({
        inv = {},
        loot = { { type = "crate", parent = crateObj, items = { item("Nails") } } },
    })
    local c = firstRow(h.match("nails"))
    h.restore()
    c.hl = nil
    c.answerCycle()
    if not Assert.isTrue(c.hl == crateObj, "cycle points at the crate") then return false end
    c.answerCycle()
    return Assert.isTrue(c.hl == crateObj, "single stash keeps cycling to itself (no error)")
end

tests["room_objects_answer_by_name"] = function()
    local room = roomOf({ roomSquare(3, 0, { "Leather Bar Seating" }),
                          roomSquare(7, 0, { "Leather Bar Seating" }),
                          roomSquare(5, 5, { "Oak Table" }) })
    local h = harness({ inv = {}, room = room })
    local rows = h.match("seating")
    local c = firstRow(rows)
    h.restore()
    if not Assert.notNil(c, "room object answers by name") then return false end
    if not Assert.isTrue(c.source:find("2", 1, true) ~= nil, "counts the instances") then return false end
    if not Assert.isTrue(c.source:find("3", 1, true) ~= nil, "states the NEAREST distance") then return false end
    local first = c.hl
    c.answerCycle()
    c.answerCycle()
    return Assert.isTrue(c.hl ~= first, "cycle walks the instances")
end

tests["item_answer_beats_room_object_of_same_name"] = function()
    local room = roomOf({ roomSquare(4, 0, { "Hammer" }) })
    local h = harness({ inv = { item("Hammer") }, room = room })
    local rows = h.match("hammer")
    h.restore()
    if not Assert.equal(#rows, 1, "one row, not two") then return false end
    return Assert.isTrue(rows[1].c.source:find("on you", 1, true) ~= nil, "the count row wins")
end

tests["time_answers_watch_gated"] = function()
    local h = harness({ inv = {}, watch = true, hour = 14.5 })
    local c = firstRow(h.match("what time"), function(r) return r.kind == "answer" end)
    h.restore()
    if not Assert.notNil(c, "time row materializes") then return false end
    if not Assert.isTrue(c.label:find("2:30", 1, true) ~= nil, "watch: the real clock (2:30 PM)") then return false end
    local h2 = harness({ inv = {}, watch = false, hour = 14.5 })
    local c2 = firstRow(h2.match("time"))
    h2.restore()
    return Assert.isTrue(c2.label:find("probably", 1, true) ~= nil, "no watch: the honest guess")
end

tests["filter_merges_answers_below_real_matches"] = function()
    local h = harness({ inv = { item("Nails") } })
    local real = { label = "Take Nails", category = "loot", kind = "loot",
                   runnable = true, run = function() end }
    local s = { allCommands = { real }, playerNum = 0 }
    SP.Filter.run(s, "nails")
    h.restore()
    if not Assert.isTrue(#s.filtered >= 2, "real match + answer row") then return false end
    if not Assert.equal(s.filtered[1].label, "Take Nails", "the ACTION outranks the answer") then return false end
    local ans = nil
    for _, c in ipairs(s.filtered) do if c.kind == "answer" then ans = c end end
    return Assert.notNil(ans, "the answer row rides along")
end

tests["ui_enter_on_answer_cycles_and_stays_open"] = function()
    local cycled = false
    local row = { label = "Nails", category = "count", kind = "answer",
                  runnable = true, run = function() end,
                  answerCycle = function() cycled = true end }
    local root = States.build({ commands = { row } })
    root.sel = 1
    D.enter(root)
    if not Assert.isTrue(cycled, "Enter drove the cycle") then return false end
    return Assert.equal(D.closed, false, "the box stayed open")
end

return tests
