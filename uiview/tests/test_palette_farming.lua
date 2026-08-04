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
    spy.seeded = nil
    _G.ISTimedActionQueue = { add = function() spy.queued = spy.queued + 1 end }
    _G.CFarmingSystem = { instance = { getLuaObjectOnSquare = function(_, sq) return opts.plant end } }
    _G.ISFarmingMenu = { canDigHereSquare = function() return opts.diggable == true end }
    -- vanilla's water-uses helper: present only when a test opts in, so the
    -- getCurrentUses fallback stays covered too
    if opts.waterUses then
        _G.ISFarmingMenu.getWaterUsesInteger = function() return opts.waterUses end
    end
    _G.ISHarvestPlantAction = { new = function() return {} end }
    _G.ISWaterPlantAction = { new = function() return {} end }
    _G.ISFertilizeAction = { new = function() return {} end }
    _G.ISShovelAction = { new = function() return {} end }
    _G.ISPlowAction = { new = function() return {} end }
    _G.ISCurePlantAction = { new = function() return {} end }
    _G.ISSeedActionNew = { new = function(_, _, _, typeOfSeed) spy.seeded = typeOfSeed; return {} end }
    _G.ItemTag = _G.ItemTag or { FERTILIZER = "Fertilizer", COMPOST = "Compost", DIG_PLOW = "DigPlow" }
    _G.ItemTag.IS_SEED = _G.ItemTag.IS_SEED or "IsSeed"
    _G.ItemTag.IS_CUTTING = _G.ItemTag.IS_CUTTING or "IsCutting"
    -- the crop table sowing enumerates (seedTypes list + seedName-only spellings)
    _G.farming_vegetableconf = { props = {
        Carrots  = { seedTypes = { "Base.CarrotSeed" } },
        Cabbages = { seedName = "Base.CabbageSeed" },
    } }
    _G.instanceof = _G.instanceof or function(it, cls) return type(it) == "table" and it._type == cls end
    _G.luautils = _G.luautils or {}; _G.luautils.walkAdj = function() return true end
    _G.getText = _G.getText or function(k) return k end
    local tools = {}
    for _, t in ipairs(opts.items or {}) do tools[#tools + 1] = t end
    local inv = { getFirstEvalRecurse = function(_, pred)
        for _, it in ipairs(tools) do if pred(it) then return it end end
    end, getFirstTypeEvalRecurse = function(_, fullType, pred)
        for _, it in ipairs(tools) do
            if it.getFullType and it:getFullType() == fullType and pred(it) then return it end
        end
    end }
    local sq = { getX = function() return 0 end, getY = function() return 0 end, getZ = function() return 0 end }
    local sq2 = { getX = function() return 1 end, getY = function() return 0 end, getZ = function() return 0 end }
    _G.getCell = function() return { getGridSquare = function(_, x, y)
        if x == 0 and y == 0 then return sq end
        if opts.twoFurrows and x == 1 and y == 0 then return sq2 end
    end } end
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
-- a plantable seed packet; overlay `extra` to spoil it (Food-shaped: _isFood + isRotten…)
local function seedItem(fullType, extra)
    local it = { getFullType = function() return fullType end,
                 hasTag = function(_, t) return t == "IsSeed" end,
                 getTexture = function() return "seed-tex" end,
                 isWaterSource = function() return false end, getCurrentUses = function() return 0 end,
                 isBroken = function() return false end }
    if extra then for k, v in pairs(extra) do it[k] = v end end
    return it
end

local function find(cmds, sub) for _, c in ipairs(cmds) do if tostring(c.label):find(sub, 1, true) then return c end end end

local tests = {}

tests["harvestable_plant_offers_harvest"] = function()
    local row = find(collect({ plant = plant("harvest") }), "Harvest")
    if not Assert.notNil(row, "a ripe crop -> Harvest") then return false end
    if not Assert.isTrue(row.runnable == true, "harvest needs no tool") then return false end
    return Assert.equal(row.category, "farm", "farm category")
end

tests["seeded_plant_water_needs_a_source"] = function()
    -- nothing to pour with: ONE honest blocked row named for the plant, no amounts
    local cmds = collect({ plant = plant("seeded"), items = {} })
    local dry = find(cmds, "Water")
    if not Assert.notNil(dry, "Water row shown") then return false end
    if not Assert.isTrue(dry.runnable == false, "no water -> blocked") then return false end
    local n = 0
    for _, c in ipairs(cmds) do if c.kind == "waterplant" then n = n + 1 end end
    if not Assert.equal(n, 0, "blocked state offers no pour amounts") then return false end
    local wet = find(collect({ plant = plant("seeded"), items = { waterItem() } }), "Pour all")
    return Assert.isTrue(wet ~= nil and wet.runnable == true, "with a water source -> a runnable pour row")
end

-- ── pour amounts: one use = 10 waterLvl ─────────────────────────────────────
local function pourLabels(cmds)
    local t = {}
    for _, c in ipairs(cmds) do if c.kind == "waterplant" then t[c.label] = c.order end end
    return t
end

tests["water_offers_amounts_in_tens"] = function()
    -- plant at 40 needs 6 uses; the bottle holds 5 -> capped at what you carry
    local amts = pourLabels(collect({ plant = plant("seeded"), items = { waterItem() } }))
    if not Assert.notNil(amts["Pour all 50 you have"], "capped fill names the real amount") then return false end
    if not Assert.equal(amts["Pour all 50 you have"], 0, "the fill is the family default (order 0)") then return false end
    for u = 1, 4 do
        if not Assert.notNil(amts["+" .. (u * 10) .. " water"], "+" .. (u * 10) .. " offered") then return false end
    end
    return Assert.isNil(amts["+50 water"], "no increment duplicating the fill")
end

tests["water_fill_when_you_carry_enough"] = function()
    -- 20 uses available, plant needs 6 -> the default fills it and stops there
    local big = waterItem(); big.getCurrentUses = function() return 20 end
    local amts = pourLabels(collect({ plant = plant("seeded"), items = { big } }))
    if not Assert.notNil(amts["Fill it up"], "enough water -> 'Fill it up'") then return false end
    return Assert.isNil(amts["+60 water"], "amounts stop at what the plant needs")
end

tests["water_amount_follows_the_vanilla_helper"] = function()
    -- a B42 fluid container lies via getCurrentUses; the real read is
    -- ISFarmingMenu.getWaterUsesInteger, so the amounts must follow IT
    local bottle = waterItem(); bottle.getCurrentUses = function() return 99 end
    local amts = pourLabels(collect({ plant = plant("seeded"), items = { bottle }, waterUses = 3 }))
    if not Assert.notNil(amts["Pour all 30 you have"], "amounts follow the vanilla helper, not getCurrentUses") then return false end
    return Assert.isNil(amts["+30 water"], "no increment duplicating the fill")
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

tests["furrow_with_seed_offers_plant"] = function()
    local row = find(collect({ plant = plant("plow"), items = { seedItem("Base.CarrotSeed") } }), "Plant Carrots")
    if not Assert.notNil(row, "a furrow + carrot seeds -> Plant Carrots") then return false end
    if not Assert.isTrue(row.runnable == true, "seed in bag -> runnable") then return false end
    if not Assert.notNil(row.hl, "planting highlights the furrow") then return false end
    return Assert.equal(row.category, "farm", "farm category")
end

tests["furrow_without_seeds_shows_blocked_plant_row"] = function()
    local row = find(collect({ plant = plant("plow"), items = { plowItem() } }), "Plant Seeds")
    return Assert.isTrue(row ~= nil and row.runnable == false, "no seeds -> one greyed Plant Seeds row")
end

tests["only_carried_crops_are_offered"] = function()
    local cmds = collect({ plant = plant("plow"), items = { seedItem("Base.CarrotSeed") } })
    return Assert.isNil(find(cmds, "Plant Cabbages"), "no cabbage seed carried -> no Plant Cabbages row")
end

tests["seedname_only_crops_resolve"] = function()
    local row = find(collect({ plant = plant("plow"), items = { seedItem("Base.CabbageSeed") } }), "Plant Cabbages")
    return Assert.isTrue(row ~= nil and row.runnable == true, "seedName-only crop spelling still plantable")
end

tests["spoiled_food_seed_is_no_seed"] = function()
    -- vanilla predicateGoodSeed: a rotten Food-shaped seed doesn't count as seed stock
    local rotten = seedItem("Base.CarrotSeed", { _type = "Food",
        isRotten = function() return true end, isCooked = function() return false end, isBurnt = function() return false end,
        isFresh = function() return false end, getBaseHunger = function() return -10 end, getHungerChange = function() return -10 end })
    local cmds = collect({ plant = plant("plow"), items = { rotten } })
    if not Assert.isNil(find(cmds, "Plant Carrots"), "rotten seed stock -> not plantable") then return false end
    return Assert.notNil(find(cmds, "Plant Seeds"), "falls back to the greyed row")
end

tests["plant_run_queues_the_sow_action"] = function()
    local row = find(collect({ plant = plant("plow"), items = { seedItem("Base.CarrotSeed") } }), "Plant Carrots")
    row.run()
    if not Assert.equal(spy.queued, 1, "running Plant walks + queues") then return false end
    return Assert.equal(spy.seeded, "Carrots", "ISSeedActionNew gets the crop type")
end

tests["two_furrows_one_plant_row_per_crop"] = function()
    local cmds = collect({ plant = plant("plow"), twoFurrows = true, items = { seedItem("Base.CarrotSeed") } })
    local n = 0
    for _, c in ipairs(cmds) do if tostring(c.label):find("Plant Carrots", 1, true) then n = n + 1 end end
    return Assert.equal(n, 1, "seed rows dedupe by crop across furrows")
end

return tests
