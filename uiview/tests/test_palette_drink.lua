--[[ pal_drink — re-surfaces "Drink" for B42 fluid-container water sources, which the
     harvested context menu buries in an onSelect=nil submenu. drinkable() gates on
     isWaterSource + a non-empty fluid container; collect() offers "Drink" (blocked for
     containers too big to drink directly, capacity > 3). ]]
local Assert = PZTestKit.Assert
local SP = require "palette/pal_drink"
local DR = SP.Drink

local function f(v) return function() return v end end
-- a fake water source with a fluid container of (cap, amt)
local function waterItem(name, cap, amt, isWater)
    local fc = { isEmpty = function() return (amt or 0) <= 0 end,
                 getCapacity = f(cap), getAmount = f(amt) }
    return { getName = f(name), getTexture = f(nil),
             isWaterSource = f(isWater ~= false), getFluidContainer = f(fc) }
end

local tests = {}

tests["drinkable_detects_a_water_bottle"] = function()
    local cap, amt = DR.drinkable(waterItem("Water (Plastic Bottle)", 1.0, 1.0))
    if not Assert.equal(cap, 1.0, "reports the capacity") then return false end
    return Assert.equal(amt, 1.0, "reports the amount")
end

tests["drinkable_rejects_non_water_and_empty"] = function()
    if not Assert.isNil(DR.drinkable(waterItem("Gas Can", 5, 5, false)), "a non-water source is not drinkable") then return false end
    return Assert.isNil(DR.drinkable(waterItem("Empty Bottle", 1.0, 0)), "an empty container is not drinkable")
end

-- collect() drives off getSpecificPlayer + the vanilla action globals
local function collectWith(invItems)
    local saved = { gsp = _G.getSpecificPlayer, da = _G.ISDrinkFluidAction, tq = _G.ISTimedActionQueue }
    local container = { getItems = function()
        return { size = function() return #invItems end, get = function(_, i) return invItems[i + 1] end }
    end }
    _G.getSpecificPlayer = function() return { getInventory = function() return container end } end
    _G.ISDrinkFluidAction = { new = function() return {} end }
    _G.ISTimedActionQueue = { add = function() end }
    local out = SP.Drink.collect(0)
    _G.getSpecificPlayer, _G.ISDrinkFluidAction, _G.ISTimedActionQueue = saved.gsp, saved.da, saved.tq
    return out
end

tests["collect_offers_drink_for_a_carried_bottle"] = function()
    local out = collectWith({ waterItem("Water (Plastic Bottle)", 1.0, 1.0) })
    if not Assert.equal(#out, 1, "one drink command for the water bottle") then return false end
    local c = out[1]
    if not Assert.equal(c.category, "drink", "category drink") then return false end
    if not Assert.equal(c.runnable, true, "a small full bottle is drinkable") then return false end
    return Assert.notNil(c.item, "carries the item so it joins the item hub")
end

tests["collect_blocks_a_too_big_container"] = function()
    -- capacity > 3 -> can't drink directly (vanilla "CantDrinkFrom")
    local out = collectWith({ waterItem("Water Dispenser", 10.0, 10.0) })
    if not Assert.equal(#out, 1, "still surfaced (discoverable)") then return false end
    return Assert.equal(out[1].runnable, false, "but blocked - too big to drink directly")
end

tests["collect_ignores_non_water_items"] = function()
    local out = collectWith({ waterItem("Gas Can", 5, 5, false) })
    return Assert.equal(#out, 0, "a non-water fluid container offers no drink")
end

return tests
