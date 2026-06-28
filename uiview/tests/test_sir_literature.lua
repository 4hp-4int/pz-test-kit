--[[
    SIR literature TooltipLib provider — offline tests
    ==================================================
    Drives SIR's real literatureCallback over mock Literature items + a recording
    ctx (the SauceTooltips offline pattern), asserting the right entries: page
    progress, skill book header + level range + can-learn, recipe magazine
    known-count. Player/perk globals are stubbed so the full path runs headlessly.
]]

local Assert = PZTestKit.Assert
require "TooltipLib/Core"
local SIR = require "sir_tooltips"

-- stub the player + perk globals the callback reads
local mockPlayer = {
    getAlreadyReadPages = function(_, ft) return 12 end,
    getKnownRecipes = function()
        return { contains = function(_, r) return r == "RecipeA" end }
    end,
    getPerkLevel = function() return 2 end,
    isLiteratureRead = function() return false end,
}
getSpecificPlayer = function() return mockPlayer end
PerkFactory = { getPerkFromName = function(n) return n end }

local function recipeList(names)
    return { size = function() return #names end,
             get = function(_, i) return names[i + 1] end }
end

local function mockBook(o)
    o = o or {}
    return {
        getNumberOfPages   = function() return o.pages or -1 end,
        getFullType        = function() return "Base.Book" end,
        getLvlSkillTrained = function() return o.skillLvl or -1 end,
        getSkillTrained    = function() return o.skill end,
        getMaxLevelTrained = function() return o.maxLvl or 0 end,
        getLearnedRecipes  = function() return o.recipes end,
        getModData         = function() return {} end,
        hasBeenSeen        = function() return false end,
    }
end

local function render(item)
    local rec = { progress = {}, kv = {}, labels = {}, headers = {} }
    local ctx = {
        item = item, playerNum = 0,
        -- match the REAL TooltipLib signatures (label/text first; colours are tables)
        addProgress  = function(_, label, frac) rec.progress[#rec.progress + 1] = { label = label, frac = frac } end,
        addKeyValue  = function(_, k, v) rec.kv[#rec.kv + 1] = { k = k, v = v } end,
        addHeader    = function(_, t) rec.headers[#rec.headers + 1] = t end,
        addLabel     = function(_, t) rec.labels[#rec.labels + 1] = t end,
    }
    local ok = pcall(SIR.Tooltips.literatureCallback, ctx)
    return ok, rec
end

local function hasHeader(rec, h) for _, x in ipairs(rec.headers) do if x == h then return true end end return false end
local function kvByKey(rec, k) for _, x in ipairs(rec.kv) do if x.k == k then return x end end return nil end

local tests = {}

tests["callback_exposed"] = function()
    return Assert.notNil(SIR.Tooltips and SIR.Tooltips.literatureCallback, "literatureCallback is exposed")
end

tests["pages_render_progress"] = function()
    local ok, rec = render(mockBook({ pages = 20 }))
    if not Assert.isTrue(ok, "callback ran") then return false end
    if not Assert.greater(#rec.progress, 0, "a page-progress entry was added") then return false end
    return Assert.equal(rec.progress[1].label, "Read 12 / 20", "progress shows read/total")
end

tests["skill_book_header_and_range"] = function()
    local ok, rec = render(mockBook({ pages = 20, skillLvl = 1, skill = "Carpentry", maxLvl = 3 }))
    if not Assert.isTrue(hasHeader(rec, "Skill Book"), "Skill Book header present") then return false end
    local kv = kvByKey(rec, "Carpentry")
    if not Assert.notNil(kv, "skill key/value present") then return false end
    return Assert.equal(kv.v, "Lv 1-3", "level range shown")
end

tests["skill_book_can_learn"] = function()
    -- player perk level 2; book trains Lv 1-3 -> can still learn
    local _, rec = render(mockBook({ pages = 20, skillLvl = 1, skill = "Carpentry", maxLvl = 3 }))
    local found = false
    for _, t in ipairs(rec.labels) do if tostring(t):find("can learn", 1, true) then found = true end end
    return Assert.isTrue(found, "can-learn label shown when player is in range")
end

tests["recipe_magazine_known_count"] = function()
    local _, rec = render(mockBook({ recipes = recipeList({ "RecipeA", "RecipeB" }) }))
    if not Assert.isTrue(hasHeader(rec, "Recipes"), "Recipes header present") then return false end
    local kv = kvByKey(rec, "Teaches")
    if not Assert.notNil(kv, "Teaches key/value present") then return false end
    return Assert.equal(kv.v, "1 / 2 known", "counts known recipes (RecipeA known)")
end

tests["non_book_literature_read_banner"] = function()
    -- a novel/map: no pages -> read banner path
    local _, rec = render(mockBook({ pages = -1 }))
    local found = false
    for _, t in ipairs(rec.labels) do if tostring(t):find("read", 1, true) then found = true end end
    return Assert.isTrue(found, "shows a read/not-read banner for page-less literature")
end

return tests
