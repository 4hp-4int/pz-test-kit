--[[ pal_needs — moodle-driven zero-state ranking. Was 43% covered. The NEED_SCORERS
     (category / label-keyword / item-effect / thermal) and their MAX-merge take a
     hand-built snapshot, so the core ranking is pure-testable without a live player.
     itemEffects profiles a Food item from its script getters. ]]
local Assert = PZTestKit.Assert
require "palette/pal_needs"
local SP = _G.SaucePalette
local N = SP.Needs

local function food(ft, changes)
    local g = changes or {}
    local function getter(k) return function() return g[k] or 0 end end
    return {
        _type = "Food", getFullType = function() return ft end, getFluidContainer = function() return nil end,
        getStressChange = getter("stress"), getFatigueChange = getter("fatigue"),
        getThirstChange = getter("thirst"), getHungChange = getter("hunger"),
        getUnhappyChange = getter("unhappy"), getBoredomChange = getter("boredom"),
        getPainReduction = getter("pain"), getFluReduction = getter("flu"), getEndChange = getter("endurance"),
    }
end

local tests = {}

tests["category_channel_boosts_whole_category"] = function()
    local snap = { cat = { drink = 1800 }, lbl = {}, fx = {}, memo = {} }
    local b, rk = N.boostFor({ category = "drink", label = "Drink Water" }, snap)
    if not Assert.equal(b, 1800, "thirsty -> every DRINK verb gets the category boost") then return false end
    return Assert.equal(rk, "drink", "reason = the category")
end

tests["label_keyword_boost"] = function()
    local snap = { cat = {}, lbl = { sleep = 2100 }, fx = {}, memo = {} }
    local b, rk = N.boostFor({ category = "action", label = "Sleep in Bed" }, snap)
    if not Assert.equal(b, 2100, "tired -> a 'sleep'-labelled verb floats") then return false end
    return Assert.equal(rk, "sleep", "reason = the matched keyword")
end

tests["world_baseline_carries_no_reason"] = function()
    local snap = { cat = { world = 500 }, lbl = {}, fx = {}, memo = {} }
    local b, rk = N.boostFor({ category = "world", label = "Open Door" }, snap)
    if not Assert.equal(b, 500, "world verbs get the situational baseline") then return false end
    return Assert.isTrue(rk == nil, "the world baseline is not a 'need' -> no why-tag")
end

tests["max_merge_takes_strongest_channel"] = function()
    -- both category (1000) and label (2600) apply -> MAX, not sum
    local snap = { cat = { med = 1000 }, lbl = { bandage = 2600 }, fx = {}, memo = {} }
    local b, rk = N.boostFor({ category = "med", label = "Apply Bandage" }, snap)
    if not Assert.equal(b, 2600, "the strongest single channel wins (not the sum)") then return false end
    return Assert.equal(rk, "bandage", "reason = the winning channel")
end

tests["item_effect_profiles_food_on_consume_verb"] = function()
    local saved = _G.instanceof
    _G.instanceof = function(o, c) return type(o) == "table" and o._type == c end
    local soda = food("Base.NeedsPop", { thirst = -20 })
    local fx = N.itemEffects(soda, {})
    local snap = { cat = {}, lbl = {}, fx = { thirst = 1400 }, memo = {} }
    local b, rk = N.boostFor({ category = "drink", label = "Drink Pop", item = soda }, snap)
    _G.instanceof = saved
    if not Assert.notNil(fx, "a thirst-quenching food profiles to an effect set") then return false end
    if not Assert.isTrue(fx.thirst == true, "the effect set marks thirst") then return false end
    if not Assert.equal(b, 1400, "fx boost applies on a consume verb") then return false end
    return Assert.equal(rk, "thirst", "reason = the effect")
end

tests["item_effect_skipped_on_non_consume_verb"] = function()
    -- "Equip water bottle" must NOT rise from thirst (equip isn't a consume verb)
    local saved = _G.instanceof
    _G.instanceof = function(o, c) return type(o) == "table" and o._type == c end
    local soda = food("Base.NeedsPop2", { thirst = -20 })
    local snap = { cat = {}, lbl = {}, fx = { thirst = 1400 }, memo = {} }
    local b = (N.boostFor({ category = "equip", label = "Equip Bottle", item = soda }, snap))
    _G.instanceof = saved
    return Assert.equal(b, 0, "fx never lifts a non-consume verb")
end

tests["thermal_only_warms_clothing_wear"] = function()
    local saved = _G.instanceof
    _G.instanceof = function(o, c) return type(o) == "table" and o._type == c end
    local coat = { _type = "Clothing" }
    local snap = { cat = {}, lbl = {}, fx = {}, memo = {}, warm = 900 }
    local bWear = (N.boostFor({ category = "equip", label = "Wear Warm Coat", item = coat }, snap))
    local bOff  = (N.boostFor({ category = "equip", label = "Unequip Warm Coat", item = coat }, snap))
    local bAxe  = (N.boostFor({ category = "equip", label = "Equip Axe", item = { _type = "HandWeapon" } }, snap))
    _G.instanceof = saved
    if not Assert.equal(bWear, 900, "cold -> a Clothing WEAR row warms up") then return false end
    if not Assert.equal(bOff, 0, "but NOT an unequip row (shedding layers is the opposite)") then return false end
    return Assert.equal(bAxe, 0, "and NOT a weapon (only warm clothing reads 'cold')")
end

return tests
