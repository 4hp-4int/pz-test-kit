--[[
    UIView — pal_farming (tend crops from the palette)
    ==================================================
    Drives the real farming collect() against a stubbed CFarmingSystem (plant per
    square) + an inventory item check. Asserts: a harvestable plant -> Harvest; a
    seeded plant -> Water (runnable only with a water source) + Fertilize; a furrow ->
    Remove Furrow (with a digging tool); diggable dirt -> Plow; rows carry the farm
    category; the run walks + queues the vanilla action.
]]

local Assert = PZTestKit.Assert
local SP = require "palette/pal_farming"

local function list(items) return { size = function() return #items end, get = function(_, i) return items[i + 1] end } end

-- a plant on the centre square; `kind` = harvest|seeded|plow
local function plant(kind)
    return { typeOfSeed = "Carrots", state = (kind == "plow") and "plow" or "seeded",
             waterLvl = 40, canHarvest = function() return kind == "harvest" end,
             isAlive = function() return true end }
end

local spy = { queued = 0 }
local function collect(opts)
    opts = opts or {}
    spy.queued = 0
    _G.ISTimedActionQueue = { add = function() spy.queued = spy.queued + 1 end }
    _G.CFarmingSystem = { instance = { getLuaObjectOnSquare = function(_, sq) return opts.plant end } }
    _G.ISFarmingMenu = { canDigHereSquare = function() return opts.diggable == true end }
    _G.ISHarvestPlantAction = { new = function() return {} end }
    _G.ISWaterPlantAction = { new = function() return {} end }
    _G.ISFertilizeAction = { new = function() return {} end }
    _G.ISShovelAction = { new = function() return {} end }
    _G.ISPlowAction = { new = function() return {} end }
    _G.ItemTag = _G.ItemTag or { FERTILIZER = "Fertilizer", COMPOST = "Compost", DIG_PLOW = "DigPlow" }
    _G.luautils = _G.luautils or {}; _G.luautils.walkAdj = function() return true end
    _G.getText = _G.getText or function(k) return k end
    local tools = {}
    for _, t in ipairs(opts.items or {}) do tools[#tools + 1] = t end
    local inv = { getFirstEvalRecurse = function(_, pred)
        for _, it in ipairs(tools) do if pred(it) then return it end end
    end }
    local sq = { getX = function() return 0 end, getY = function() return 0 end, getZ = function() return 0 end }
    _G.getCell = function() return { getGridSquare = function(_, x, y) if x == 0 and y == 0 then return sq end end } end
    local p = { _type = "IsoPlayer", getInventory = function() return inv end, getCurrentSquare = function() return sq end }
    _G._pz_player = p
    for _, s in ipairs(SP.sources) do if s.id == "farming" then return s.collect(0) end end
end

local function waterItem() return { isWaterSource = function() return true end, getCurrentUses = function() return 5 end,
                                     isBroken = function() return false end, hasTag = function() return false end } end
local function fertItem()  return { isWaterSource = function() return false end, getCurrentUses = function() return 3 end,
                                    isBroken = function() return false end, hasTag = function(_, t) return t == "Fertilizer" end } end
local function plowItem()  return { isWaterSource = function() return false end, getCurrentUses = function() return 0 end,
                                    isBroken = function() return false end, hasTag = function(_, t) return t == "DigPlow" end } end

local function find(cmds, sub) for _, c in ipairs(cmds) do if tostring(c.label):find(sub, 1, true) then return c end end end

local tests = {}

tests["harvestable_plant_offers_harvest"] = function()
    local row = find(collect({ plant = plant("harvest") }), "Harvest")
    if not Assert.notNil(row, "a ripe crop -> Harvest") then return false end
    if not Assert.isTrue(row.runnable == true, "harvest needs no tool") then return false end
    return Assert.equal(row.category, "farm", "farm category")
end

tests["seeded_plant_water_needs_a_source"] = function()
    local dry = find(collect({ plant = plant("seeded"), items = {} }), "Water")
    if not Assert.notNil(dry, "Water row shown") then return false end
    if not Assert.isTrue(dry.runnable == false, "no water -> blocked") then return false end
    local wet = find(collect({ plant = plant("seeded"), items = { waterItem() } }), "Water")
    return Assert.isTrue(wet.runnable == true, "with a water source -> runnable")
end

tests["seeded_plant_fertilize_gated"] = function()
    local row = find(collect({ plant = plant("seeded"), items = { fertItem() } }), "Fertilize")
    return Assert.isTrue(row ~= nil and row.runnable == true, "fertilizer in bag -> Fertilize runnable")
end

tests["furrow_offers_remove_with_tool"] = function()
    local row = find(collect({ plant = plant("plow"), items = { plowItem() } }), "Remove Furrow")
    return Assert.isTrue(row ~= nil and row.runnable == true, "a furrow + digging tool -> Remove Furrow")
end

tests["diggable_dirt_offers_plow"] = function()
    local row = find(collect({ diggable = true, items = { plowItem() } }), "Plow")
    return Assert.isTrue(row ~= nil and row.runnable == true, "diggable dirt + tool -> Plow")
end

tests["run_walks_and_queues"] = function()
    local row = find(collect({ plant = plant("harvest") }), "Harvest")
    row.run()
    return Assert.equal(spy.queued, 1, "running Harvest walks + queues the vanilla action")
end

tests["empty_no_rows"] = function()
    return Assert.equal(#collect({}), 0, "nothing farmable -> no rows")
end

return tests
