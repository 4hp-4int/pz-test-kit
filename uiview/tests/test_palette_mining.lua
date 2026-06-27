--[[
    UIView — pal_mining (chop trees, mine ore/flint, dig stumps)
    ============================================================
    Drives the real gather collect() against a stubbed 3x3 world whose centre square
    carries a tree, an ore, and a stump, plus an inventory tool check. Asserts: each
    node yields its verb by name; the verb is runnable with the right tool and greyed
    (with a reason) without it; rows carry the chop/mine category + highlight the node;
    ore names from getObjectName ("Mine Flint").
]]

local Assert = PZTestKit.Assert
local SP = require "palette/pal_mining"

local function list(items) return { size = function() return #items end, get = function(_, i) return items[i + 1] end } end

-- a world node (tree/ore/stump) on a square
local function node(name) return { _type = "IsoObject", getObjectName = function() return name end,
                                   getSquare = function() return _G._theSquare end, getSprite = function() return nil end } end

-- set up: a centre square with optional tree/ore/stump; an inventory that "carries"
-- the tools named in `tools` (a set of predicate-passing fake items). Returns cmds.
-- shared spies, reset each collect, so a run-test can prove equip + the action fire.
local spy = { equippedWith = nil, queued = 0 }
local function collect(opts)
    opts = opts or {}
    spy.equippedWith, spy.queued = nil, 0
    _G.ISTimedActionQueue = { add = function() spy.queued = spy.queued + 1 end }
    _G.ISWorldObjectContextMenu = { equip = function(_, _, pred) spy.equippedWith = pred end }
    _G.ISChopTreeAction = { new = function() return {} end }
    _G.ISPickAxeGroundCoverItem = { new = function() return {} end }
    _G.ISRemoveBush = { new = function() return {} end }
    _G.ISScything = { new = function() return {} end }
    _G.ISRemovePlantCursor = { new = function(_, _, removeType)
        return { getRemovableObject = function(_, _sq)
            if removeType == "bush" then return opts.bush elseif removeType == "grass" then return opts.grass end
        end }
    end }
    _G.ItemTag = _G.ItemTag or { CHOP_TREE = "ChopTree", PICK_AXE = "PickAxe", STONE_MAUL = "StoneMaul",
                                 SLEDGEHAMMER = "Sledgehammer", CLUB_HAMMER = "ClubHammer", REMOVE_STUMP = "RemoveStump",
                                 CUT_PLANT = "CutPlant", SCYTHE = "Scythe", HAND_SCYTHE = "HandScythe" }
    local sq = { getX = function() return 0 end, getY = function() return 0 end, getZ = function() return 0 end,
                 HasTree = function() return opts.tree ~= nil end,
                 getTree = function() return opts.tree end,
                 getOre = function() return opts.ore end,
                 getStump = function() return opts.stump end }
    _G._theSquare = sq
    _G.getCell = function() return { getGridSquare = function(_, x, y) if x == 0 and y == 0 then return sq end end } end
    _G.luautils = _G.luautils or {}; _G.luautils.walkAdj = function() return true end
    -- inventory: a tool is "carried" if its tag is in opts.tags
    local tools = {}
    for _, t in ipairs(opts.tags or {}) do
        tools[#tools + 1] = { isBroken = function() return false end,
                              hasTag = function(_, tag) return tag == t end }
    end
    local inv = { containsEvalRecurse = function(_, pred)
        for _, it in ipairs(tools) do if pred(it) then return true end end
        return false
    end, getFirstEvalRecurse = function(_, pred)
        for _, it in ipairs(tools) do if pred(it) then return it end end
    end }
    local p = { _type = "IsoPlayer", getInventory = function() return inv end,
                getCurrentSquare = function() return sq end, getPrimaryHandItem = function() return nil end }
    _G._pz_player = p
    for _, s in ipairs(SP.sources) do if s.id == "mining" then return s.collect(0) end end
end

local function find(cmds, sub) for _, c in ipairs(cmds) do if tostring(c.label):find(sub, 1, true) then return c end end end

local tests = {}

tests["chop_tree_offered_with_axe"] = function()
    local tree = node("Tree")
    local cmds = collect({ tree = tree, tags = { "ChopTree" } })
    local row = find(cmds, "Chop Tree")
    if not Assert.notNil(row, "a tree + axe -> Chop Tree") then return false end
    if not Assert.isTrue(row.runnable == true, "runnable with an axe") then return false end
    if not Assert.equal(row.category, "chop", "chop category") then return false end
    return Assert.equal(row.hl, tree, "highlights the tree")
end

tests["chop_tree_blocked_without_axe"] = function()
    local cmds = collect({ tree = node("Tree"), tags = {} })
    local row = find(cmds, "Chop Tree")
    if not Assert.notNil(row, "still shown so you know it's possible") then return false end
    if not Assert.isTrue(row.runnable == false, "no axe -> blocked") then return false end
    return Assert.notNil(row.blockReason, "with a reason")
end

tests["mine_ore_named_from_object"] = function()
    local cmds = collect({ ore = node("Flint"), tags = { "PickAxe" } })
    local row = find(cmds, "Mine Flint")
    if not Assert.notNil(row, "an ore named Flint -> Mine Flint") then return false end
    if not Assert.equal(row.category, "mine", "mine category") then return false end
    return Assert.isTrue(row.runnable == true, "runnable with a pickaxe")
end

tests["mine_blocked_without_pick"] = function()
    local row = find(collect({ ore = node("Iron Ore"), tags = { "ChopTree" } }), "Mine Iron Ore")
    return Assert.isTrue(row ~= nil and row.runnable == false, "an axe doesn't mine ore -> blocked")
end

tests["dig_stump_offered"] = function()
    local cmds = collect({ stump = node("Stump"), tags = { "RemoveStump" } })
    local row = find(cmds, "Dig up Stump")
    return Assert.isTrue(row ~= nil and row.runnable == true and row.category == "mine", "stump + remove-stump tool -> Dig up Stump")
end

tests["all_three_nodes_distinct_rows"] = function()
    local cmds = collect({ tree = node("Tree"), ore = node("Flint"), stump = node("Stump"),
                           tags = { "ChopTree", "PickAxe", "RemoveStump" } })
    return Assert.isTrue(find(cmds, "Chop Tree") ~= nil and find(cmds, "Mine Flint") ~= nil and find(cmds, "Dig up Stump") ~= nil,
        "tree + ore + stump each get their own verb")
end

tests["run_equips_the_tool_then_queues_the_action"] = function()
    local cmds = collect({ ore = node("Flint"), tags = { "PickAxe" } })
    local row = find(cmds, "Mine Flint")
    if not Assert.notNil(row, "Mine Flint row") then return false end
    local ok = row.run()
    if not Assert.isTrue(ok == true, "run succeeds (reachable)") then return false end
    if not Assert.notNil(spy.equippedWith, "run EQUIPS a tool (vanilla equip helper called)") then return false end
    -- the equip predicate is the pickaxe matcher: it should accept a pickaxe, reject an axe
    if not Assert.isTrue(spy.equippedWith({ isBroken = function() return false end,
        hasTag = function(_, t) return t == "PickAxe" end }), "equip predicate accepts a pickaxe") then return false end
    return Assert.equal(spy.queued, 1, "and queues the mining action")
end

tests["cut_bush_offered_with_cutting_tool"] = function()
    local bush = node("Bush")
    local row = find(collect({ bush = bush, tags = { "CutPlant" } }), "Cut Bush")
    if not Assert.notNil(row, "a bush + cutting tool -> Cut Bush") then return false end
    if not Assert.isTrue(row.runnable == true, "runnable with a machete/saw") then return false end
    return Assert.equal(row.hl, bush, "highlights the bush")
end

tests["cut_bush_blocked_without_tool"] = function()
    local row = find(collect({ bush = node("Bush"), tags = {} }), "Cut Bush")
    return Assert.isTrue(row ~= nil and row.runnable == false, "no cutting tool -> blocked with a reason")
end

tests["scythe_grass_offered_with_scythe"] = function()
    local row = find(collect({ grass = node("Grass"), tags = { "Scythe" } }), "Scythe Grass")
    if not Assert.notNil(row, "tall grass + scythe -> Scythe Grass") then return false end
    return Assert.isTrue(row.runnable == true and row.category == "chop", "runnable, chop category")
end

tests["scythe_run_queues_the_action"] = function()
    local row = find(collect({ grass = node("Grass"), tags = { "Scythe" } }), "Scythe Grass")
    local ok = row.run()
    if not Assert.isTrue(ok == true, "run succeeds (reachable)") then return false end
    return Assert.equal(spy.queued, 1, "queues the scythe action with the found item")
end

tests["no_vegetation_no_cut_rows"] = function()
    -- holding the tools but nothing to cut -> no Cut/Scythe rows (right thing at right time)
    local cmds = collect({ tags = { "CutPlant", "Scythe" } })
    return Assert.isTrue(find(cmds, "Cut Bush") == nil and find(cmds, "Scythe Grass") == nil,
        "no bush/grass present -> no vegetation rows even with tools")
end

tests["empty_area_no_rows"] = function()
    return Assert.equal(#collect({ tags = { "PickAxe" } }), 0, "no nodes nearby -> no gather rows")
end

return tests
