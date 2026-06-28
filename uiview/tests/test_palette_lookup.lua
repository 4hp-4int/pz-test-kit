--[[ pal_lookup — recipe search (the informational "what does X need" results).
     Distinct from craft: lookup surfaces recipes by NAME regardless of whether you
     can make them, is non-runnable, ranks below actionables, and its detail flags
     missing ingredients / environment blocks. Was 22% covered (no test file) — the
     exact kind of low-coverage path a definition-order/nil bug ships in unnoticed. ]]
local Assert    = PZTestKit.Assert
local CraftMock = require "UIView/CraftMock"
local RecipeDB  = require "UIView/RecipeDB"
require "palette/pal_craft"    -- provides SP.recipeName / SP.recipeDetail / SP.blockReason
require "palette/pal_lookup"
local SP = _G.SaucePalette

local function withDB(items, fn)
    SP.Lookup._index = nil               -- (defensive) bust any cached index
    RecipeDB.install()
    CraftMock.install(items or {})
    local ok, err = pcall(fn)
    CraftMock.restore(); RecipeDB.restore()
    if not ok then error(err) end
end

local tests = {}

tests["short_query_returns_nothing"] = function()
    local out
    withDB({}, function() out = SP.Lookup.query("s", 0) end)   -- < 2 chars
    return Assert.equal(#out, 0, "a 1-char query yields no lookup results")
end

tests["matches_recipe_by_name_substring"] = function()
    local out
    withDB({}, function() out = SP.Lookup.query("saw", 0) end)
    local hit
    for _, c in ipairs(out) do if c.label == "Saw Log" then hit = c end end
    if not Assert.notNil(hit, "'saw' surfaces the Saw Log recipe") then return false end
    if not Assert.equal(hit.category, "lookup", "lookup category") then return false end
    return Assert.equal(hit.runnable, false, "lookup rows are informational, never runnable")
end

tests["miss_returns_empty"] = function()
    local out
    withDB({}, function() out = SP.Lookup.query("zzzznomatch", 0) end)
    return Assert.equal(#out, 0, "a non-matching query yields nothing")
end

tests["detail_builds_without_error"] = function()
    -- The detail closure rebuilds a logic + calls SP.recipeDetail — exercise it.
    local d
    withDB({ CraftMock.item("Base.Log") }, function()
        local out = SP.Lookup.query("saw", 0)
        for _, c in ipairs(out) do
            if c.label == "Saw Log" and c.buildDetail then d = c.buildDetail() end
        end
    end)
    if not Assert.notNil(d, "the lookup row built a detail model") then return false end
    return Assert.notNil(d.title, "the detail has a title")
end

tests["too_dark_blocks_with_a_light_reason"] = function()
    -- ingredients present (craftCount>0) + tooDark + recipe not doable in dark -> "needs light"
    local hit
    CraftMock.tooDark = true
    withDB({ CraftMock.item("Base.Log") }, function()
        -- mark Saw Log as NOT doable in the dark for this run
        for _, spec in ipairs(RecipeDB.FIXTURES) do if spec.name == "Saw Log" then spec.dark = false end end
        local out = SP.Lookup.query("saw", 0)
        for _, c in ipairs(out) do if c.label == "Saw Log" then hit = c end end
    end)
    CraftMock.tooDark = false
    for _, spec in ipairs(RecipeDB.FIXTURES) do if spec.name == "Saw Log" then spec.dark = nil end end
    if not Assert.notNil(hit, "Saw Log still listed when blocked") then return false end
    return Assert.notNil(hit.blockReason, "carries a block reason (needs light) when too dark with ingredients")
end

return tests
