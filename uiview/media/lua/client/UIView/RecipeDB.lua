--[[
    RecipeDB — a fixture recipe database for the uiview harness.
    ============================================================
    CraftMock fakes individual recipes as trivial stubs. RecipeDB goes further: a
    small but REAL-shaped set of B42 craft recipes (inputs, tools, skills, tags,
    outputs) exposed through the actual PZ query API — getScriptManager()
    :getAllCraftRecipes() / :getCraftRecipe(name), CraftRecipeManager.queryRecipes,
    and the Perks table. This lets us unit-test code that walks the recipe DB:
    sir_craftindex (the skill-lens reverse-index), pal_craft.collect, etc.

    install() swaps the globals in; restore() puts them back. Fixtures live in
    RecipeDB.FIXTURES — add rows to widen coverage.
]]

local RecipeDB = {}

local function jlist(t)
    return { size = function() return #t end, get = function(_, i) return t[i + 1] end }
end

-- tag -> item fulltypes it resolves to (what getPossibleInputItems expands a
-- tag-based input into). Mirrors how B42 inputs accept "any <tag>" items.
RecipeDB.TAG_ITEMS = {
    RipClothingCotton  = { "Base.Tshirt", "Base.Socks" },
    RipClothingDenim   = { "Base.Jeans" },
    RipClothingLeather = { "Base.LeatherJacket" },
    ScrapAsBelt        = { "Base.Belt" },
    Saw                = { "Base.Saw", "Base.GardenSaw" },
    Hammer             = { "Base.Hammer", "Base.BallPeenHammer" },
    Scissors           = { "Base.Scissors" },
    SharpKnife         = { "Base.HuntingKnife" },
    BlowTorch          = { "Base.BlowTorch" },
    Welder             = { "Base.WeldingMask" },
}

-- spec: { name, skills = {Woodwork=2,...}, inputs = { {items|tags, isTool, auto, amount} },
--         outputs = {fulltypes}, tags = {}, surface, ws, floor }
RecipeDB.FIXTURES = {
    -- clothing rip (no skill)
    { name = "RipClothing",      inputs = { { tags = { "RipClothingCotton" } } },                                       outputs = { "Base.RippedSheets" } },
    { name = "RipDenimClothing", inputs = { { tags = { "RipClothingDenim" } }, { tags = { "Scissors" }, isTool = true } }, outputs = { "Base.DenimStrips" } },
    { name = "CutUpBelt",        inputs = { { tags = { "ScrapAsBelt" } }, { tags = { "Scissors" }, isTool = true } },      outputs = { "Base.LeatherStrips" } },
    -- woodwork (Carpentry=Woodwork) + carving
    { name = "Saw Log",          skills = { Woodwork = 0 }, inputs = { { items = { "Base.Log" }, amount = 1 }, { tags = { "Saw" }, isTool = true } },          outputs = { "Base.Plank" } },
    { name = "Make Chair",       skills = { Woodwork = 2 }, inputs = { { items = { "Base.Plank" }, amount = 4 }, { items = { "Base.Nails" } }, { tags = { "Hammer" }, isTool = true } }, outputs = { "Base.WoodenChair" } },
    { name = "Carve Spoon",      skills = { Carving = 1 },  inputs = { { items = { "Base.WoodSculpture" } }, { tags = { "SharpKnife" }, isTool = true } },      outputs = { "Base.WoodenSpoon" } },
    -- blacksmith
    { name = "Forge Knife",      skills = { Blacksmith = 3 }, inputs = { { items = { "Base.SteelIngot" } }, { tags = { "Hammer" }, isTool = true } },          outputs = { "Base.ForgedKnife" }, ws = true },
    -- welding
    { name = "Weld Plate",       skills = { MetalWelding = 2 }, inputs = { { items = { "Base.MetalSheet" } }, { tags = { "BlowTorch" }, isTool = true } },     outputs = { "Base.MetalPlate" } },
    -- packing: a bulk unpack — one generic recipe, an output mapper, many contents.
    -- Drives pal_craft's per-subject expansion (one row per box you carry).
    { name = "Open Box (100 Items)", category = "Packing", mapper = true, outAmount = 100,
      inputs = { { items = { "Base.NailsBox", "Base.ScrewsBox", "Base.CapGunCapBox" } } }, outputs = { "Base.Nails" } },
}

local function mkItemScript(ft)
    return { getFullName = function() return ft end,
             getDisplayName = function() return (ft:gsub("^.-%.", "")) end }
end

local function mkInput(ins, TAG)
    local items = {}
    for _, ft in ipairs(ins.items or {}) do items[#items + 1] = mkItemScript(ft) end
    for _, tag in ipairs(ins.tags or {}) do
        for _, ft in ipairs(TAG[tag] or {}) do items[#items + 1] = mkItemScript(ft) end
    end
    return {
        isTool                = function() return ins.isTool or false end,
        isAutomationOnly      = function() return ins.auto or false end,
        getIntAmount          = function() return ins.amount or 1 end,
        getResourceType       = function() return _G.ResourceType and _G.ResourceType.Item end,
        getPossibleInputItems = function() return jlist(items) end,
    }
end

local function mkRecipe(spec, TAG)
    local inputs = {}
    for _, ins in ipairs(spec.inputs or {}) do inputs[#inputs + 1] = mkInput(ins, TAG) end
    local outputs = {}
    for _, ft in ipairs(spec.outputs or {}) do
        outputs[#outputs + 1] = {
            getItem = function() return mkItemScript(ft) end,
            getIntAmount = function() return spec.outAmount or 1 end, getChance = function() return 1 end,
            -- spec.mapper => an output mapper (its result resolves to this output ft);
            -- enough to drive isUnpackRecipe + SP.Resolve.recipeOutput(o, recipeData).
            getOutputMapper = function()
                if not spec.mapper then return nil end
                return {
                    isEmpty = function() return false end,
                    getResultItems = function() return jlist({ mkItemScript(ft) }) end,
                    getOutputItem = function() return mkItemScript(ft) end,
                }
            end,
        }
    end
    return {
        getName            = function() return spec.name end,
        getTranslationName = function() return spec.name end,
        getCategory        = function() return spec.category or "Other" end,
        canBeDoneInDark    = function() return spec.dark ~= false end,
        involvesSkill      = function(_, perk)
            return (spec.skills and perk and spec.skills[perk._name] ~= nil) or false
        end,
        getInputs   = function() return jlist(inputs) end,
        getOutputs  = function() return jlist(outputs) end,
        getTags     = function() return jlist(spec.tags or {}) end,
        getIconTexture = function() return nil end,
        isAnySurfaceCraft = function() return spec.surface or false end,
        requiresSpecificWorkstation = function() return spec.ws or false end,
        isCanBeDoneFromFloor = function() return spec.floor ~= false end,
    }
end

local SAVED = {}
local NAMES = { "getScriptManager", "ScriptManager", "CraftRecipeManager", "Perks", "ResourceType" }

function RecipeDB.install()
    for _, n in ipairs(NAMES) do SAVED[n] = _G[n] end

    local recipes, byName = {}, {}
    for _, spec in ipairs(RecipeDB.FIXTURES) do
        local r = mkRecipe(spec, RecipeDB.TAG_ITEMS)
        recipes[#recipes + 1] = r
        byName[spec.name] = r
    end

    local sm = {
        getAllCraftRecipes = function() return jlist(recipes) end,
        getCraftRecipe     = function(_, name) return byName[name] end,
    }
    _G.getScriptManager = function() return sm end
    _G.ScriptManager = { instance = sm }
    _G.CraftRecipeManager = {
        queryRecipes = function(_) return jlist(recipes) end,   -- ignore the query filter
    }
    _G.Perks = setmetatable({
        Woodwork = { _name = "Woodwork" }, Carving = { _name = "Carving" },
        Blacksmith = { _name = "Blacksmith" }, MetalWelding = { _name = "MetalWelding" },
    }, { __index = function(_, k) return { _name = k } end })
    _G.ResourceType = _G.ResourceType or { Item = "Item" }

    return recipes
end

-- ── real-corpus mode ───────────────────────────────────────────────────────
-- installReal() wraps the parsed real PZ recipes (RealRecipes.lua, generated by
-- tools/parse_recipes.py) in mock objects that mirror the API our resolver calls —
-- so SP.Resolve / category / family logic can be swept over the ACTUAL B42 corpus,
-- not hand-rolled fixtures. The mocks mirror real behaviour where it matters: a
-- mapper output's getItem(nil) returns the mapper DEFAULT (the wrong-item case our
-- resolver must NOT trust), getOutputMapper exposes the real result set.
local function realItem(ft)
    local disp = tostring(ft):gsub("^.-%.", "")
    return { getFullName = function() return ft end, getDisplayName = function() return disp end,
             getNormalTexture = function() return nil end }
end

local function realMapper(m)
    local results = {}
    for _, ft in ipairs(m.results or {}) do results[#results + 1] = realItem(ft) end
    return {
        isEmpty = function() return #results == 0 end,
        getResultItems = function() return jlist(results) end,
        getOutputItem = function(_, _) return (m.default and realItem(m.default)) or results[1] end,
    }
end

local function realOutput(o, mappers)
    local mp = o.mapper and mappers[o.mapper] or nil
    return {
        getIntAmount = function() return o.amount or 1 end,
        getChance = function() return 1 end,
        getOutputMapper = function() return mp and realMapper(mp) or nil end,
        getItem = function(_, rd)
            if o.item then return realItem(o.item) end
            if mp then
                -- WITH recipe data the real mapper resolves to the consumed input's
                -- result (concrete); WITHOUT data it returns its DEFAULT (or nil if it
                -- has none) — the wrong-item case our resolver must not trust.
                if rd ~= nil then return realItem(mp.default or mp.results[1]) end
                return mp.default and realItem(mp.default) or nil
            end
            return nil
        end,
    }
end

local function realInput(i)
    local items = {}
    for _, ft in ipairs(i.items or {}) do items[#items + 1] = realItem(ft) end
    local tags = i.tags or {}
    return {
        isTool = function() return i.tool == true end,
        isAutomationOnly = function() return false end,
        getIntAmount = function() return i.amount or 1 end,
        getPossibleInputItems = function() return jlist(items) end,
        getItemTags = function()
            return {
                isEmpty = function() return #tags == 0 end,
                iterator = function()
                    local k = 0
                    return { hasNext = function() return k < #tags end,
                             next = function() k = k + 1; return tags[k] end }
                end,
            }
        end,
    }
end

local function realRecipe(r)
    local inputs = {}; for _, i in ipairs(r.inputs or {}) do inputs[#inputs + 1] = realInput(i) end
    local outputs = {}; for _, o in ipairs(r.outputs or {}) do outputs[#outputs + 1] = realOutput(o, r.mappers or {}) end
    local tags = {}; for _, t in ipairs(r.tags or {}) do tags[#tags + 1] = t end
    return {
        getName = function() return r.name end,
        getTranslationName = function() return r.name end,
        getCategory = function() return r.category end,
        getTags = function() return jlist(tags) end,
        getInputs = function() return jlist(inputs) end,
        getOutputs = function() return jlist(outputs) end,
        getIconTexture = function() return nil end,
        isAnySurfaceCraft = function() return false end,
        requiresSpecificWorkstation = function() return false end,
        isCanBeDoneFromFloor = function() return true end,
        canBeDoneInDark = function() return true end,
    }
end

-- Returns the wrapped recipe list (and the raw parsed table). queryRecipes serves them.
function RecipeDB.installReal()
    for _, n in ipairs(NAMES) do SAVED[n] = _G[n] end
    local raw = require "UIView/RealRecipes"
    local recipes, byName = {}, {}
    for _, r in ipairs(raw) do
        local rec = realRecipe(r)
        recipes[#recipes + 1] = rec
        byName[r.name] = rec
    end
    local sm = { getAllCraftRecipes = function() return jlist(recipes) end,
                 getCraftRecipe = function(_, name) return byName[name] end }
    _G.getScriptManager = function() return sm end
    _G.CraftRecipeManager = { queryRecipes = function(_) return jlist(recipes) end }
    return recipes, raw
end

function RecipeDB.restore()
    for _, n in ipairs(NAMES) do _G[n] = SAVED[n] end
end

return RecipeDB
