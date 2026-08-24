--[[
    UIView — Medical provider mock harness
    ======================================
    pal_medical.collect() reads the live player / BodyDamage / inventory and the
    first-aid timed-action classes. The actual treatment EXECUTION can't run in
    the Kahlua harness (no real items/actions), but the DETECTION + command
    emission (which injuries surface which verbs, runnable vs blocked, the torso
    exclusion) is pure logic we can drive with mocks.

    Med.collectWith({ hasMoodle=, parts={...}, items={...} }) -> the commands the
    provider would emit for that body/inventory state.
]]

require "UIView/UIMock"

-- Globals the provider resolves at collect time.
MoodleType    = { Injured = 1, Pain = 2, Bleeding = 3, Sick = 4, HasACold = 5 }
BodyPartType  = { Head = "Head", Torso_Upper = "Torso_Upper", Torso_Lower = "Torso_Lower",
                  getDisplayName = function(t) return tostring(t) end }
ResourceLocation = { of = function(s) return s end }
ItemTag       = { get = function(s) return s end }      -- token == tag name
ComponentType = { FluidContainer = "FluidContainer" }
if instanceof == nil then function instanceof() return false end end

require "palette/pal_medical"   -- registers SP.Medical
local SP = _G.SaucePalette

local Med = {}

local function mockItem(def)
    def = def or {}
    return {
        getType = function() return def.type or "X" end,
        getName = function() return def.name or def.type or "X" end,
        getBandagePower = function() return def.bandage or 0 end,
        getAlcoholPower = function() return def.alcohol or 0 end,
        IsDrainable = function() return def.drainable or false end,
        hasComponent = function() return false end,
        getCurrentUsesFloat = function() return def.uses or 1 end,
        IsInventoryContainer = function() return false end,
        hasTag = function(_, t) return (def.tags and def.tags[t]) or false end,
        getTexture = function() return getTexture("Item_" .. (def.type or "X")) end,
    }
end
Med.item = mockItem

local function listOf(t)
    return { size = function() return #t end, get = function(_, i) return t[i + 1] end }
end

local function mockPart(def)
    def = def or {}
    return {
        getType = function() return def.type or "Hand_L" end,
        HasInjury = function() return def.injury ~= false end,
        stitched = function() return def.stitched or false end,
        bandaged = function() return def.bandaged or false end,
        getSplintFactor = function() return def.splintFactor or 0 end,
        getFractureTime = function() return def.fracture or 0 end,
        haveGlass = function() return def.glass or false end,
        haveBullet = function() return def.bullet or false end,
        isDeepWounded = function() return def.deep or false end,
        getWoundInfectionLevel = function() return def.infection or 0 end,
        isNeedBurnWash = function() return def.burn or false end,
        bleeding = function() return def.bleeding or false end,
        isBandageDirty = function() return def.bandageDirty or false end,
        getBandageType = function() return def.bandageType end,
    }
end
Med.part = mockPart

local function mockPlayer(def)
    local parts, items = {}, {}
    for _, p in ipairs(def.parts or {}) do parts[#parts + 1] = mockPart(p) end
    for _, i in ipairs(def.items or {}) do items[#items + 1] = mockItem(i) end
    return {
        getMoodles = function()
            return { getMoodleLevel = function() return def.hasMoodle and 1 or 0 end }
        end,
        getBodyDamage = function()
            -- The provider gates on moodle OR overall health < 100 (a bandaged part
            -- whose wound has quieted shows no moodle). Default 100 = untouched, so a
            -- `hasMoodle = false` def really is a healthy player unless it says so.
            return { getOverallBodyHealth = function() return def.health or 100 end,
                     getBodyParts = function() return listOf(parts) end }
        end,
        getInventory = function() return { getItems = function() return listOf(items) end } end,
    }
end

function Med.collectWith(def)
    getSpecificPlayer = function() return mockPlayer(def) end
    local ok, cmds = pcall(SP.Medical.collect, 0)
    return ok and cmds or {}
end

-- find a command by exact verb prefix ("Splint", "Remove Glass", ...)
function Med.find(cmds, verb)
    for _, c in ipairs(cmds) do
        if tostring(c.label):find("^" .. verb .. " %- ") then return c end
    end
    return nil
end

return Med
