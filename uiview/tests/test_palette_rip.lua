--[[ pal_rip — "Rip all clothing" provider, exercised headlessly via CraftMock.
     Verifies: the command surfaces with a live count, queues one action per
     rippable item, routes each fabric to its correct recipe, and skips
     worn/favorited/non-rippable items. ]]
local Assert    = PZTestKit.Assert
local CraftMock = require "UIView/CraftMock"
require "palette/pal_rip"
local SP = _G.SaucePalette

local function ripSource()
    for _, src in ipairs(SP.sources or {}) do
        if src.id == "rip" then return src end
    end
end

-- install mocks, run fn under them, always restore (no global leak between tests)
local function withItems(items, fn)
    CraftMock.install(items)
    local ok, res = pcall(fn)
    CraftMock.restore()
    if not ok then error(res) end
    return res
end

local tests = {}

tests["rip_all_queues_one_per_item_with_right_recipe"] = function()
    return withItems({
        CraftMock.clothing("Tshirt", "base:ripclothingcotton"),
        CraftMock.clothing("Jeans",  "base:ripclothingdenim"),
        CraftMock.clothing("Jacket", "base:ripclothingleather"),
        CraftMock.clothing("Belt",   "base:scrapasbelt"),
        CraftMock.clothing("Hat",    "base:notrippable"),                  -- not rippable
        CraftMock.clothing("FavTee", "base:ripclothingcotton", { fav = true }),      -- favorited -> skip
        CraftMock.clothing("WornTee","base:ripclothingcotton", { equipped = true }), -- worn -> skip
    }, function()
        local src = ripSource()
        if not Assert.equal(src ~= nil, true, "rip source registered") then return false end
        local cmds = src.collect(0)
        -- 4 per-fabric commands (cotton/denim/leather/belts) + 1 combined "all"
        if not Assert.equal(#cmds, 5, "per-fabric commands + combined surface") then return false end

        local byLabel = {}
        for _, c in ipairs(cmds) do byLabel[c.label] = c end
        if not Assert.equal(byLabel["Rip all denim (1)"] ~= nil, true, "denim command present") then return false end
        if not Assert.equal(byLabel["Rip all leather (1)"] ~= nil, true, "leather command present") then return false end
        if not Assert.equal(byLabel["Rip all clothing (4)"] ~= nil, true, "combined command present") then return false end
        if not Assert.equal(byLabel["Rip all denim (1)"].runnable, true, "denim command runnable") then return false end

        -- rip ONLY denim -> one RipDenimClothing action
        byLabel["Rip all denim (1)"].run()
        if not Assert.equal(#CraftMock.queue, 1, "denim command queues just the denim item") then return false end
        if not Assert.equal(CraftMock.queue[1].recipe, "RipDenimClothing", "denim -> RipDenimClothing") then return false end

        -- combined -> all 4, routed per fabric (reset the recorder first)
        CraftMock.queue = {}
        byLabel["Rip all clothing (4)"].run()
        local byRecipe = {}
        for _, a in ipairs(CraftMock.queue) do byRecipe[a.recipe] = (byRecipe[a.recipe] or 0) + 1 end
        if not Assert.equal(byRecipe["RipClothing"], 1, "cotton -> RipClothing") then return false end
        if not Assert.equal(byRecipe["RipDenimClothing"], 2, "denim + leather -> RipDenimClothing") then return false end
        return Assert.equal(byRecipe["CutUpBelt"], 1, "belt -> CutUpBelt")
    end)
end

tests["no_command_when_nothing_rippable"] = function()
    return withItems({ CraftMock.clothing("Hat", "base:notrippable") }, function()
        return Assert.equal(#ripSource().collect(0), 0, "no rip command when nothing rippable")
    end)
end

return tests
