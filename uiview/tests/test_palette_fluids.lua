--[[
    UIView — pal_fluids (transfer liquid without the slider dialog)
    ===============================================================
    Drives the real fluids collect() against stubbed fluid items + a global
    FluidContainer.CanTransfer. Asserts: each container becomes a node labelled with
    its level; a fuller compatible source yields a "Fill from <S>" row (the fullest is
    tier 0 = default); a non-empty container offers Empty; a full container offers no
    Fill; an incompatible pair yields no fill row.
]]

local Assert = PZTestKit.Assert
local SP = require "palette/pal_fluids"

-- a fake fluid item: amt/cap define its level; `compatWith` (a set) gates CanTransfer.
local function fluidItem(name, amt, cap)
    local fc = {
        _amt = amt, _cap = cap,
        getAmount = function(self) return self._amt end,
        getCapacity = function(self) return self._cap end,
        getFreeCapacity = function(self) return self._cap - self._amt end,
        isEmpty = function(self) return self._amt <= 0 end,
        getPrimaryFluid = function() return nil end,
    }
    return {
        _type = "InventoryItem",
        getName = function() return name end,
        getTexture = function() return nil end,
        getFluidContainer = function() return fc end,
    }, fc
end

local function list(items)
    return { size = function() return #items end, get = function(_, i) return items[i + 1] end }
end

-- run collect with a set of fluid items in the player inventory. `compat` = function
-- (srcFc, tgtFc) -> bool for the global CanTransfer stub (default: always true).
-- `waterSq` (optional) = a grid square the player stands on, for world-source tests.
local function collect(items, compat, waterSq)
    _G.ISFluidContainer = _G.ISFluidContainer or { new = function() return {} end }
    _G.ISFluidTransferAction = _G.ISFluidTransferAction or {}
    _G.ISFluidEmptyAction = _G.ISFluidEmptyAction or {}
    _G.ISTimedActionQueue = _G.ISTimedActionQueue or {}
    _G.FluidContainer = { CanTransfer = compat or function() return true end,
                          GetTransferReason = function() return "incompatible" end }
    local inv = { getItems = function() return list(items) end }
    local p = { _type = "IsoPlayer", getInventory = function() return inv end,
                getCurrentSquare = function() return waterSq end }
    _G._pz_player = p
    for _, s in ipairs(SP.sources) do if s.id == "fluids" then return s.collect(0) end end
end

-- a grid cell containing one water-source object, reachable via getCell()/getGridSquare.
-- Returns (square, sink, restore) — call restore() to undo the global stubs so they
-- don't leak into other test files (which also use getCell()).
local function waterWorld()
    local sink = { _type = "IsoObject", hasWater = function() return true end,
                   isTaintedWater = function() return false end }
    local sq = { getX = function() return 0 end, getY = function() return 0 end, getZ = function() return 0 end,
                 getObjects = function() return list({ sink }) end }
    local oCell, oMenu, oText = _G.getCell, _G.ISWorldObjectContextMenu, _G.getText
    _G.getCell = function() return { getGridSquare = function(_, x, y) if x == 0 and y == 0 then return sq end end } end
    _G.ISWorldObjectContextMenu = { onTakeWater = function() end }
    _G.getText = _G.getText or function(k) return k end
    local function restore() _G.getCell, _G.ISWorldObjectContextMenu, _G.getText = oCell, oMenu, oText end
    return sq, sink, restore
end

local function find(cmds, sub)
    for _, c in ipairs(cmds) do if tostring(c.label):find(sub, 1, true) then return c end end
    return nil
end

local tests = {}

tests["container_level_in_the_name"] = function()
    local bottle = fluidItem("Water Bottle", 0.8, 2.0)
    local cmds = collect({ bottle })
    -- a lone non-empty container at least offers Empty, named with its level
    local row = find(cmds, "Empty")
    if not Assert.notNil(row, "a non-empty lone container offers Empty") then return false end
    return Assert.notNil(tostring(row.flName):find("0.8/2.0", 1, true), "the node names the fluid level")
end

tests["fill_from_a_fuller_source"] = function()
    local bottle = fluidItem("Water Bottle", 0.0, 2.0)   -- empty target
    local bucket = fluidItem("Bucket", 5.0, 10.0)        -- a source
    local cmds = collect({ bottle, bucket })
    return Assert.notNil(find(cmds, "Fill from Bucket"), "the empty bottle can Fill from the Bucket")
end

tests["fullest_source_is_the_default_tier"] = function()
    local bottle = fluidItem("Water Bottle", 0.0, 5.0)
    local little = fluidItem("Mug", 0.2, 0.5)
    local big    = fluidItem("Bucket", 8.0, 10.0)
    local cmds = collect({ bottle, little, big })
    local fromBig = find(cmds, "Fill from Bucket")
    if not Assert.notNil(fromBig, "fill from the big source exists") then return false end
    return Assert.equal(fromBig.flTier, 0, "the fullest source is the default (tier 0)")
end

tests["full_container_offers_no_fill"] = function()
    local full = fluidItem("Water Bottle", 2.0, 2.0)
    local src  = fluidItem("Bucket", 5.0, 10.0)
    local cmds = collect({ full, src })
    -- the full bottle gets no Fill row (no room); it still offers Empty
    local fillIntoFull = nil
    for _, c in ipairs(cmds) do
        if tostring(c.flName):find("Water Bottle", 1, true) and tostring(c.label):find("Fill", 1, true) then fillIntoFull = c end
    end
    return Assert.isTrue(fillIntoFull == nil, "a full container shows no Fill row")
end

tests["incompatible_fluids_no_fill"] = function()
    local bottle = fluidItem("Water Bottle", 0.0, 2.0)
    local gas    = fluidItem("Gas Can", 5.0, 10.0)
    local cmds = collect({ bottle, gas }, function() return false end)   -- never compatible
    return Assert.isTrue(find(cmds, "Fill from") == nil, "incompatible fluids -> no Fill row")
end

tests["rows_are_fluid_category"] = function()
    local bottle = fluidItem("Water Bottle", 0.0, 2.0)
    local bucket = fluidItem("Bucket", 5.0, 10.0)
    return Assert.equal(find(collect({ bottle, bucket }), "Fill from Bucket").category, "fluid",
        "fluid rows carry the fluid category")
end

tests["fill_from_world_water_source"] = function()
    local sq, sink, restore = waterWorld()
    local bottle = fluidItem("Water Bottle", 0.0, 2.0)
    bottle.canStoreWater = function() return true end
    local r = Assert.notNil(find(collect({ bottle }, nil, sq), "Fill from"),
        "a water container near a sink can Fill from the world source")
    restore()
    return r
end

tests["world_source_is_default_and_highlights"] = function()
    local sq, sink, restore = waterWorld()
    local bottle = fluidItem("Water Bottle", 0.0, 2.0)
    bottle.canStoreWater = function() return true end
    local row = find(collect({ bottle }, nil, sq), "Fill from")
    local r = row and row.flTier == 0 and row.hl == sink
    restore()
    return Assert.isTrue(r, "world-source fill is the default (tier 0) and highlights the source")
end

tests["non_water_container_ignores_world_source"] = function()
    local sq, sink, restore = waterWorld()
    local gas = fluidItem("Gas Can", 0.0, 10.0)
    gas.canStoreWater = function() return false end   -- not a water container
    local r = Assert.isTrue(find(collect({ gas }, nil, sq), "Fill from") == nil,
        "a non-water container gets no world-source fill")
    restore()
    return r
end

tests["family_collapses_per_container"] = function()
    local bottle = fluidItem("Water Bottle", 0.5, 2.0)
    local bucket = fluidItem("Bucket", 5.0, 10.0)
    local cmds = collect({ bottle, bucket })
    SP.Families.apply(cmds)
    -- bottle's Fill + Empty share one family key
    local bottleRows = {}
    for _, c in ipairs(cmds) do if tostring(c.flName):find("Water Bottle", 1, true) then bottleRows[#bottleRows + 1] = c end end
    if not Assert.isTrue(#bottleRows >= 2, "the bottle has Fill + Empty") then return false end
    return Assert.equal(bottleRows[1].familyKey, bottleRows[2].familyKey, "they collapse under one container family")
end

return tests
