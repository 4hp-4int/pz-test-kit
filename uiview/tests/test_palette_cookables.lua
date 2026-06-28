--[[ pal_cookables — BBQ/campfire family. collect() needs the live fire API (no
     harness mock), but the family that folds a fire object's verbs is pure data:
     noun head + verbs as flavor (blocked marked "*"), Enter -> primary available
     verb. Same shape as moveables. ]]
local Assert = PZTestKit.Assert
local SP = require "palette/pal_cookables"
local Families = SP.Families

local function ckCmd(verb, name, runnable)
    return { label = verb .. " - " .. name, kind = "cookable", ckName = name,
             ckVerb = verb, runnable = runnable ~= false, source = name }
end

-- collect-driven coverage: a fire object on a tile + a stubbed camping fuel kit.
local Fixtures = PZTestKit.Fixtures
local function cookableCollect()
    for _, s in ipairs(SP.sources) do if s.id == "cookable" then return s.collect end end
end
local function makeFire(o)
    local obj = { _type = "IsoBarbecue" }
    obj.isFireInteractionObject = function(self) return true end
    obj.isLit          = function(self) return o.lit or false end
    obj.hasFuel        = function(self) return o.hasFuel ~= false end
    obj.getFuelAmount  = function(self) return o.fuelAmount or 0 end
    obj.isPropaneBBQ   = function(self) return o.propane or false end
    obj.hasPropaneTank = function(self) return o.hasTank or false end
    return obj
end
local function collectLive(o, fuelKit)
    o = o or {}
    _G.ISTimedActionQueue = _G.ISTimedActionQueue or {}
    _G.getCampingFuelMax = function() return 100 end
    _G.ISCampingMenu = { getNearbyFuelInfo = function(p) return fuelKit or {} end }
    local world = Fixtures.world()
    local center = world:square(3, 3, 0)
    table.insert(center._private.objects, makeFire(o))
    _G._pz_player = Fixtures.player({ square = center })
    return cookableCollect()(0)
end
local function find(cmds, sub)
    for _, c in ipairs(cmds) do if tostring(c.label):find(sub, 1, true) then return c end end
    return nil
end

local tests = {}

tests["source_and_family_present"] = function()
    if not Assert.notNil(SP.Cookables and SP.Cookables.collect, "cookable source collect exists") then return false end
    return Assert.notNil(Families and Families.apply, "Families.apply present")
end

tests["fire_verbs_collapse_noun_head_verb_flavor"] = function()
    local cmds = {
        ckCmd("Light",          "Barbecue", true),
        ckCmd("Add Fuel",       "Barbecue", true),
        ckCmd("Remove Propane", "Barbecue", true),
    }
    Families.apply(cmds)
    local key
    for _, c in ipairs(cmds) do
        if not Assert.notNil(c.familyKey, "verb stamped with familyKey") then return false end
        key = key or c.familyKey
        if not Assert.equal(c.familyKey, key, "verbs share one family key") then return false end
    end
    if not Assert.equal(cmds[1].familyLabel, "Barbecue", "head = noun") then return false end
    return Assert.equal(cmds[1].familyFlavor, "Light, Add Fuel, Remove Propane", "verbs as flavor in rank order")
end

tests["blocked_light_marked_and_default_available"] = function()
    -- Light blocked (no lighter), Add Fuel available -> head still noun, Light
    -- shows with "*", default (Enter) is the available Add Fuel.
    local cmds = {
        ckCmd("Light",    "Campfire", false),
        ckCmd("Add Fuel", "Campfire", true),
    }
    Families.apply(cmds)
    if not Assert.equal(cmds[1].familyFlavor, "Add Fuel, Light*", "available first, blocked Light marked *") then return false end
    local def; for _, c in ipairs(cmds) do if c.familyDefault then def = c end end
    return Assert.equal(def and def.label, "Add Fuel - Campfire", "default is the available verb")
end

-- ── collect() driven (real source over a fixture fire) ──────────────────────
tests["collect_light_runnable_with_kit"] = function()
    -- petrol + starters + fuel in the BBQ -> Light is available.
    local cmds = collectLive({ lit = false, hasFuel = true },
        { starters = { {} }, petrol = {}, tinder = {}, fuelList = {} })
    local row = find(cmds, "Light")
    return Assert.isTrue(row ~= nil and row.runnable == true, "fuel kit + fuel -> Light runnable")
end

tests["collect_light_blocked_no_lighter"] = function()
    -- no starters (no lighter) -> Light shown but blocked with a reason.
    local cmds = collectLive({ lit = false, hasFuel = true }, { starters = {}, fuelList = {} })
    local row = find(cmds, "Light")
    if not Assert.isTrue(row ~= nil and row.runnable == false, "no lighter -> Light blocked") then return false end
    return Assert.notNil(row.blockReason, "blocked with a reason")
end

tests["collect_lit_fire_offers_put_out"] = function()
    local cmds = collectLive({ lit = true }, { fuelList = {} })
    return Assert.notNil(find(cmds, "Put Out"), "a lit fire offers Put Out")
end

tests["collect_propane_insert_when_tankless"] = function()
    -- propane BBQ without a tank, but a tank found nearby -> Insert Propane.
    _G.ISBBQMenu = { FindPropaneTank = function(p, obj) return { _type = "InventoryItem" } end }
    local cmds = collectLive({ lit = false, propane = true, hasTank = false }, { starters = {}, fuelList = {} })
    return Assert.notNil(find(cmds, "Insert Propane"), "tankless propane BBQ + nearby tank -> Insert Propane")
end

return tests
