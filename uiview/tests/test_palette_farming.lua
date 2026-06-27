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

-- a plant on the centre square; `kind` = harvest|seeded|plow|dead. `extra` overlays
-- fields (e.g. disease levels: { mildewLvl = 50 }).
local function plant(kind, extra)
    local pl = { typeOfSeed = "Carrots",
                 state = (kind == "plow") and "plow" or (kind == "dead") and "dead" or "seeded",
                 waterLvl = 40, canHarvest = function() return kind == "harvest" end,
                 isAlive = function() return kind ~= "dead" end }
    if extra then for k, v in pairs(extra) do pl[k] = v end end
    return pl
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
    _G.ISCurePlantAction = { new = function() return {} end }
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
local function sprayItem(t) return { getType = function() return t end, getCurrentUses = function() return 2 end,
                                     isWaterSource = function() return false end, isBroken = function() return false end,
                                     hasTag = function() return false end } end

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

tests["diseased_plant_offers_cure_gated_on_spray"] = function()
    local without = find(collect({ plant = plant("seeded", { mildewLvl = 50 }), items = {} }), "Treat Mildew")
    if not Assert.notNil(without, "a sick plant shows Treat Mildew so you know it's diseased") then return false end
    if not Assert.isTrue(without.runnable == false, "no spray -> blocked") then return false end
    local with = find(collect({ plant = plant("seeded", { mildewLvl = 50 }), items = { sprayItem("GardeningSprayMilk") } }), "Treat Mildew")
    return Assert.isTrue(with ~= nil and with.runnable == true, "mildew spray in bag -> Treat Mildew runnable")
end

tests["only_the_actual_disease_is_offered"] = function()
    -- aphids only: Treat Aphids appears, the other three do not
    local cmds = collect({ plant = plant("seeded", { aphidLvl = 30 }), items = { sprayItem("GardeningSprayAphids") } })
    if not Assert.notNil(find(cmds, "Treat Aphids"), "aphid plant -> Treat Aphids") then return false end
    return Assert.isNil(find(cmds, "Treat Mildew"), "no mildew level -> no Treat Mildew row")
end

tests["healthy_plant_has_no_cure_rows"] = function()
    local row = find(collect({ plant = plant("seeded"), items = { sprayItem("GardeningSprayMilk") } }), "Treat")
    return Assert.isNil(row, "no disease -> no Treat rows even with spray on hand")
end

tests["dead_plant_offers_clear"] = function()
    local row = find(collect({ plant = plant("dead"), items = { plowItem() } }), "Clear Dead")
    return Assert.isTrue(row ~= nil and row.runnable == true, "a dead plant + digging tool -> Clear Dead")
end

tests["actions_highlight_the_tile"] = function()
    -- no cursor opens for farming, so the row must point at its target tile (hl = square)
    local plow = find(collect({ diggable = true, items = { plowItem() } }), "Plow")
    if not Assert.notNil(plow and plow.hl, "Plow highlights its target tile") then return false end
    local harvest = find(collect({ plant = plant("harvest") }), "Harvest")
    return Assert.notNil(harvest and harvest.hl, "Harvest highlights the plot too")
end

tests["empty_no_rows"] = function()
    return Assert.equal(#collect({}), 0, "nothing farmable -> no rows")
end

return tests
