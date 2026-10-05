--[[
    Script catalog: every script type the engine's ScriptManager holds,
    grouped for browsing (family -> type -> group -> entry).

    Tools:  scriptTypes{}                 families + per-type counts
            scriptList{type, q, limit}    entries grouped (category for items
                                          and recipes, module otherwise)
            scriptInfo{type, name}        one entry: describe() of the object

    `kw` is the block keyword in media/scripts, so the server can attach the
    source text (workbench.js augments scriptInfo with it).
]]

local function sm() return getScriptManager() end
local try = WB.try
local function s(v) if v == nil then return nil end return tostring(v) end

local TYPES = {
    { id = "items",          label = "Items",               family = "Items & crafting", kw = "item",          get = function() return sm():getAllItems() end,
      group = function(o) return s(try(function() return o:getDisplayCategory() end)) end },
    { id = "craftRecipes",   label = "Craft recipes",       family = "Items & crafting", kw = "craftRecipe",   get = function() return sm():getAllCraftRecipes() end,
      group = function(o) return s(try(function() return o:getCategory() end)) end },
    { id = "fixing",         label = "Fixing (repair)",     family = "Items & crafting", kw = "fixing",        get = function() return sm():getAllFixing(ArrayList.new()) end },
    { id = "evolved",        label = "Evolved recipes",     family = "Items & crafting", kw = "evolvedrecipe", get = function() return sm():getAllEvolvedRecipesList() end },
    { id = "entities",       label = "Entities (build)",    family = "Items & crafting", kw = "entity",        get = function() return sm():getAllGameEntities() end },
    { id = "itemFilters",    label = "Item filters",        family = "Items & crafting", kw = "itemFilter",    get = function() return sm():getAllItemFilters() end },
    { id = "itemConfigs",    label = "Item configs",        family = "Items & crafting", kw = "itemConfig",    get = function() return sm():getAllItemConfigs() end },
    { id = "timedActions",   label = "Timed actions",       family = "Items & crafting", kw = "timedAction",   get = function() return sm():getAllTimedActionScripts() end },
    { id = "fluids",         label = "Fluids",              family = "Fluids & energy",  kw = "fluid",         get = function() return sm():getAllFluidDefinitionScripts() end },
    { id = "fluidFilters",   label = "Fluid filters",       family = "Fluids & energy",  kw = "fluidFilter",   get = function() return sm():getAllFluidFilters() end },
    { id = "energy",         label = "Energy",              family = "Fluids & energy",  kw = "energy",        get = function() return sm():getAllEnergyDefinitionScripts() end },
    { id = "models",         label = "Models",              family = "Models & animation", kw = "model",       get = function() return sm():getAllModelScripts() end },
    { id = "spriteModels",   label = "Sprite models",       family = "Models & animation", kw = "spriteModel", get = function() return sm():getAllSpriteModels() end },
    { id = "animMeshes",     label = "Animation meshes",    family = "Models & animation", kw = "animationsMesh", get = function() return sm():getAllAnimationsMeshes() end },
    { id = "runtimeAnims",   label = "Runtime animations",  family = "Models & animation", kw = "animation",   get = function() return sm():getAllRuntimeAnimationScripts() end },
    { id = "mannequins",     label = "Mannequins",          family = "Models & animation", kw = "mannequin",   get = function() return sm():getAllMannequinScripts() end },
    { id = "physicsShapes",  label = "Physics shapes",      family = "Models & animation", kw = "physicsShape", get = function() return sm():getAllPhysicsShapes() end },
    { id = "sounds",         label = "Game sounds",         family = "Sound",            kw = "sound",         get = function() return sm():getAllGameSounds() end,
      group = function(o) return s(try(function() return o:getCategory() end)) end },
    { id = "soundTimelines", label = "Sound timelines",     family = "Sound",            kw = "soundTimeline", get = function() return sm():getAllSoundTimelines() end },
    { id = "vehicles",       label = "Vehicles",            family = "Vehicles",         kw = "vehicle",       get = function() return sm():getAllVehicleScripts() end },
    { id = "vehicleTemplates", label = "Vehicle templates", family = "Vehicles",         kw = "template",      get = function() return sm():getAllVehicleTemplates() end },
    { id = "engineRPM",      label = "Engine RPM curves",   family = "Vehicles",         kw = "vehicleEngineRPM", get = function() return sm():getAllVehicleEngineRPMs() end },
    { id = "clocks",         label = "Clocks",              family = "World & UI",       kw = "clock",         get = function() return sm():getAllClockScripts() end },
    { id = "stringLists",    label = "String lists",        family = "World & UI",       kw = "stringList",    get = function() return sm():getAllStringLists() end },
    { id = "xuiLayouts",     label = "XUI layouts",         family = "World & UI",       kw = "xuiLayout",     get = function() return sm():getAllXuiLayouts() end },
    { id = "xuiStyles",      label = "XUI styles",          family = "World & UI",       kw = "xuiStyle",      get = function() return sm():getAllXuiStyles() end },
    { id = "xuiDefaultStyles", label = "XUI default styles", family = "World & UI",      kw = "xuiDefaultStyle", get = function() return sm():getAllXuiDefaultStyles() end },
    { id = "xuiColors",      label = "XUI colors",          family = "World & UI",       kw = "xuiColors",     get = function() return sm():getAllXuiColors() end },
    { id = "xuiSkins",       label = "XUI skins",           family = "World & UI",       kw = "xuiSkin",       get = function() return sm():getAllXuiSkinScripts() end },
    { id = "xuiConfigs",     label = "XUI configs",         family = "World & UI",       kw = "xuiConfig",     get = function() return sm():getAllXuiConfigScripts() end },
}
local BY_ID = {}
for _, t in ipairs(TYPES) do BY_ID[t.id] = t end
WB.scriptTypes = BY_ID

local cache = {}
WB.scriptCaches = WB.scriptCaches or {}
WB.scriptCaches[#WB.scriptCaches + 1] = cache   -- cleared after a script reload (70_dev.lua)
local function entries(t)
    if cache[t.id] then return cache[t.id] end
    local out = {}
    local list = try(t.get)
    for _, o in ipairs(list and WB.list(list) or {}) do
        local name = s(try(function() return o:getScriptObjectName() end)) or s(try(function() return o:getName() end))
        local full = s(try(function() return o:getScriptObjectFullType() end))
        local module = s(try(function() return o:getModule():getName() end))
        if not full and name then full = (module or "Base") .. "." .. name end
        if name then
            out[#out + 1] = { name = name, full = full, module = module or "?",
                              label = t.id == "items" and s(try(function() return o:getDisplayName() end))
                                   or t.id == "craftRecipes" and s(try(function() return o:getTranslationName() end)) or nil,
                              group = t.group and t.group(o) or nil, obj = o }
        end
    end
    table.sort(out, function(a, b) return a.full < b.full end)
    cache[t.id] = out
    return out
end

WB.register("scriptTypes", function()
    local out = {}
    for _, t in ipairs(TYPES) do
        out[#out + 1] = { id = t.id, label = t.label, family = t.family, kw = t.kw, count = #entries(t) }
    end
    return { types = out }
end)

WB.register("scriptList", function(a)
    local t = BY_ID[a.type or ""]
    if not t then error("unknown script type " .. tostring(a.type)) end
    local q = a.q and a.q ~= "" and a.q:lower() or nil
    local groups, order, n, limit = {}, {}, 0, a.limit or 2000
    for _, e in ipairs(entries(t)) do
        if not q or e.full:lower():find(q, 1, true) or (e.label and e.label:lower():find(q, 1, true)) then
            -- Category first where the type has one; module otherwise, so
            -- a mod's scripts sit together instead of drowning in Base.
            local g = e.group or e.module
            if t.group and e.module ~= "Base" then g = (g or "?") .. "  (" .. e.module .. ")" end
            g = g or "?"
            if not groups[g] then groups[g] = {}; order[#order + 1] = g end
            local list = groups[g]
            list[#list + 1] = { name = e.name, full = e.full, label = e.label }
            n = n + 1
            if n >= limit then break end
        end
    end
    table.sort(order, function(x, y) return x:lower() < y:lower() end)
    local out = {}
    for _, g in ipairs(order) do out[#out + 1] = { group = g, entries = groups[g] } end
    return { type = t.id, kw = t.kw, total = n, loaded = #entries(t) > 0, byCategory = t.group ~= nil, groups = out }
end)

WB.register("scriptInfo", function(a)
    local t = BY_ID[a.type or ""]
    if not t then error("unknown script type " .. tostring(a.type)) end
    for _, e in ipairs(entries(t)) do
        if e.full == a.name or e.name == a.name then
            return { type = t.id, typeLabel = t.label, kw = t.kw, name = e.name, full = e.full, module = e.module,
                     label = e.label, group = e.group, obj = WB.describe(e.obj) }
        end
    end
    -- Not in the engine's list: the headless engine skips some script types
    -- (models, sounds, vehicles). The server fills the source in from disk.
    local name = tostring(a.name)
    return { type = t.id, typeLabel = t.label, kw = t.kw, name = name:match("[^.]+$") or name, full = name,
             module = name:match("^([^.]+)%.") or "Base", notLoaded = true }
end)
