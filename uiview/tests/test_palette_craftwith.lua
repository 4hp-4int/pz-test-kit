--[[ pal_craft.withMatches + pal_answers "with X" routing — the reverse
     ingredient lookup ("what can I craft with nails"). The rows are REAL
     craft rows (declare/detail/craftOne plumbing): Enter crafts when
     possible, blocked rows say what's missing, and the tag reads
     "uses <ingredient>". Tools are deliberately not indexed. ]]
local Assert    = PZTestKit.Assert
local CraftMock = require "UIView/CraftMock"
local RecipeDB  = require "UIView/RecipeDB"
require "palette/pal_answers"
require "palette/pal_craft"
local SP = _G.SaucePalette

local function fresh()
    SP.Craft._recipes = nil
    SP.Craft._byIng = nil
    SP.Answers._owner, SP.Answers._index, SP.Answers._roomCache = nil, nil, nil
end

-- RecipeDB gives the recipe universe (Saw Log <- Log, Make Chair <- Plank +
-- Nails, ...); CraftMock gives player/logic/containers. Restores + cache-busts
-- around `fn` so later files see a clean craft state.
local function withUniverse(items, fn)
    fresh()
    RecipeDB.install()
    CraftMock.install(items)
    local ok, err = pcall(fn)
    CraftMock.canCraft = nil
    CraftMock.restore()
    RecipeDB.restore()
    fresh()
    if not ok then error(err) end
end

local function findRow(rows, label)
    for _, rr in ipairs(rows or {}) do
        if rr.c and rr.c.label == label then return rr.c end
    end
    return nil
end

local tests = {}

tests["with_matches_finds_consumers_as_runnable_craft_rows"] = function()
    local ok = true
    withUniverse({ CraftMock.item("Base.Nails") }, function()
        local rows = SP.Craft.withMatches("nails", 0)
        local chair = findRow(rows, "Make Chair")
        ok = Assert.notNil(chair, "'nails' finds the recipe that consumes them") and ok
        if not chair then return end
        ok = Assert.equal(chair.kind, "craft", "a real craft row, not an answer row") and ok
        ok = Assert.isTrue(tostring(chair.source):find("Nails", 1, true) ~= nil,
            "the tag says which ingredient matched (uses Nails)") and ok
        ok = Assert.equal(chair.runnable, true, "craftable now -> runnable") and ok
        ok = Assert.equal(type(chair.run), "function", "Enter crafts it") and ok
        ok = Assert.equal(type(chair.buildDetail) == "function"
            or type(chair.detail) == "function", true, "carries the recipe detail") and ok
    end)
    return ok
end

tests["blocked_consumer_shows_whats_missing"] = function()
    local ok = true
    withUniverse({}, function()
        CraftMock.canCraft = false
        local rows = SP.Craft.withMatches("log", 0)
        local saw = findRow(rows, "Saw Log")
        ok = Assert.notNil(saw, "discovery: the consumer shows even when not craftable") and ok
        if not saw then return end
        ok = Assert.equal(saw.runnable, false, "not runnable while blocked") and ok
        ok = Assert.notNil(saw.blockReason, "and says why (missing inputs)") and ok
        ok = Assert.isNil(saw.run, "no run closure on a blocked row") and ok
    end)
    return ok
end

tests["tool_only_ingredients_are_not_indexed"] = function()
    local ok = true
    withUniverse({}, function()
        -- Hammer appears in Make Chair / Forge Knife ONLY as a tool
        local rows = SP.Craft.withMatches("hammer", 0)
        for _, rr in ipairs(rows or {}) do
            ok = Assert.isTrue(
                tostring(rr.c.source):lower():find("hammer", 1, true) == nil,
                "no row surfaced FOR the hammer (tools aren't 'with' subjects)") and ok
        end
    end)
    return ok
end

tests["answers_routes_with_queries_to_the_reverse_lookup"] = function()
    local ok = true
    withUniverse({ CraftMock.item("Base.Nails") }, function()
        local rows = SP.Answers.match("with nails", 0, {})
        ok = Assert.notNil(findRow(rows, "Make Chair"),
            "'with nails' in the palette surfaces the consumer recipe") and ok
        -- the wordier asks route the same way
        fresh()
        rows = SP.Answers.match("craft with plank", 0, {})
        ok = Assert.notNil(findRow(rows, "Make Chair"),
            "'craft with plank' routes too") and ok
        -- a plain item query does NOT flood craft rows
        fresh()
        local plain = SP.Answers.match("nails", 0, {}) or {}
        for _, rr in ipairs(plain) do
            ok = Assert.isTrue(rr.c.kind ~= "craft",
                "no craft rows without the 'with' ask") and ok
        end
    end)
    return ok
end

return tests
