--[[ pal_craft.craftOne pinned-input starvation fallback (the Pack Nails bug).
     The context-click pin flips HandcraftLogic to MANUAL-select mode, where
     canPerformCurrentRecipe validates only the applied selection — multi-
     count inputs (Pack Nails: 100 nails) starve there while the enumeration
     path (plain setRecipe, auto-select) says craftable. So the palette
     offered the row as runnable and then reported "no longer craftable" at
     run. craftOne must fall back to a fresh AUTO-select logic (the crafting
     window's own HandcraftStart flow) — except when a caller pinned a
     specific input via selOverride, whose failure must be honored. ]]
local Assert    = PZTestKit.Assert
local CraftMock = require "UIView/CraftMock"
require "palette/pal_craft"
local SP = _G.SaucePalette

local function withNails(fn)
    local nail = CraftMock.item("Base.Nails")
    CraftMock.install({ nail })
    local recipe = CraftMock.recipe("PackNails", "Base.Nails")
    local ok, err = pcall(fn, recipe, nail)
    CraftMock.pinStarves = nil
    CraftMock.canCraft = nil
    CraftMock.restore()
    if not ok then error(err) end
end

local tests = {}

tests["pin_starvation_falls_back_to_auto_select"] = function()
    local result
    withNails(function(recipe)
        CraftMock.pinStarves = true
        local made = SP.Craft.craftOne(0, recipe)
        local act = CraftMock.queue[#CraftMock.queue]
        result = Assert.isTrue(made == true, "craft still starts when the pinned check starves")
            and Assert.isTrue(act ~= nil and act.pinned == false,
                "fallback runs the AUTO-select logic (crafting-window flow)")
    end)
    return result
end

tests["healthy_path_keeps_the_context_pin"] = function()
    local result
    withNails(function(recipe)
        local made = SP.Craft.craftOne(0, recipe)
        local act = CraftMock.queue[#CraftMock.queue]
        result = Assert.isTrue(made == true, "craft starts")
            and Assert.isTrue(act ~= nil and act.pinned == true,
                "no fallback when the pinned check passes")
    end)
    return result
end

tests["selOverride_pin_failure_is_honored"] = function()
    local result
    withNails(function(recipe, nail)
        CraftMock.pinStarves = true
        local made = SP.Craft.craftOne(0, recipe, nail)
        result = Assert.isTrue(made ~= true,
            "a demanded specific input does NOT silently fall back to other items")
    end)
    return result
end

tests["truly_uncraftable_still_reports_blocked"] = function()
    local result
    withNails(function(recipe)
        CraftMock.canCraft = false   -- BOTH paths fail (really out of materials)
        local made = SP.Craft.craftOne(0, recipe)
        result = Assert.isTrue(made ~= true, "no craft when auto-select also fails")
    end)
    return result
end

return tests
