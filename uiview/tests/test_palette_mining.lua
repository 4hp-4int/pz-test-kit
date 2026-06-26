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
local function collect(opts)
    opts = opts or {}
    _G.ISTimedActionQueue = _G.ISTimedActionQueue or {}
    _G.ISWorldObjectContextMenu = _G.ISWorldObjectContextMenu or { equip = function() end }
    _G.ISChopTreeAction = _G.ISChopTreeAction or { new = function() return {} end }
    _G.ISPickAxeGroundCoverItem = _G.ISPickAxeGroundCoverItem or { new = function() return {} end }
    _G.ItemTag = _G.ItemTag or { CHOP_TREE = "ChopTree", PICK_AXE = "PickAxe", STONE_MAUL = "StoneMaul",
                                 SLEDGEHAMMER = "Sledgehammer", CLUB_HAMMER = "ClubHammer", REMOVE_STUMP = "RemoveStump" }
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

tests["empty_area_no_rows"] = function()
    return Assert.equal(#collect({ tags = { "PickAxe" } }), 0, "no nodes nearby -> no gather rows")
end

return tests
