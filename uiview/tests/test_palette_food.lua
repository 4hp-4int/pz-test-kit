--[[
    UIView — pal_food (what does All / 1/2 / 1/4 actually do?)
    =========================================================
    SP.Food.of(cmd) reads the live Food item + the harvested portion fraction
    (params[1] = 1 / 0.5 / 0.25) and reports the % of the hunger bar that portion
    fills and the % of the item left. Non-food / non-eat commands return nil.
]]

local Assert = PZTestKit.Assert
local SP = require "palette/pal_food"
local F = SP.Food

-- a fake Food item: base = full-item hunger fraction, cur = current remaining.
local function food(base, cur, cal)
    return {
        getBaseHunger = function() return -base end,    -- vanilla returns negative
        getHungChange = function() return -cur end,
        getCalories   = function() return cal or 0 end,
    }
end

local function eatCmd(item, fraction)
    return { category = "eat", item = item, params = { fraction } }
end

local tests = {}

tests["all_of_a_full_item_fills_the_base"] = function()
    local f = F.of(eatCmd(food(0.5, 0.5), 1))
    if not Assert.notNil(f, "a full food eat row annotates") then return false end
    if not Assert.equal(f.fillPct, 50, "All of a 0.5 food fills 50% of the hunger bar") then return false end
    return Assert.equal(f.leftPct, 100, "an untouched item is 100% left")
end

tests["half_and_quarter_scale_the_fill"] = function()
    Assert.equal(F.of(eatCmd(food(0.8, 0.8), 0.5)).fillPct, 40, "1/2 of a 0.8 food fills 40%")
    return Assert.equal(F.of(eatCmd(food(0.8, 0.8), 0.25)).fillPct, 20, "1/4 of a 0.8 food fills 20%")
end

tests["partially_eaten_item_reports_remaining"] = function()
    -- base 0.6, only 0.15 left -> 25% of the tub remains
    local f = F.of(eatCmd(food(0.6, 0.15), 1))
    return Assert.equal(f.leftPct, 25, "a tub with 0.15 of 0.6 left reads 25%")
end

tests["fill_is_capped_at_what_remains"] = function()
    -- "1/2" wants base*0.5 = 0.3, but only 0.15 remains -> fills 15%, not 30%
    local f = F.of(eatCmd(food(0.6, 0.15), 0.5))
    return Assert.equal(f.fillPct, 15, "you can't eat more than what's left")
end

tests["bad_fraction_falls_back_to_all"] = function()
    local f = F.of(eatCmd(food(0.4, 0.4), 0.33))   -- 0.33 isn't a real portion
    return Assert.equal(f.fraction, 1, "an unknown fraction is treated as All")
end

tests["calories_carried_when_present"] = function()
    return Assert.equal(F.of(eatCmd(food(0.5, 0.5), 1), 1).calories, nil, "no-calorie path stays nil")
end

tests["calories_present"] = function()
    return Assert.equal(F.of(eatCmd(food(0.5, 0.5, 320), 1)).calories, 320, "calories reported when > 0")
end

tests["non_eat_command_is_nil"] = function()
    return Assert.isTrue(F.of({ category = "drop", item = food(0.5, 0.5) }) == nil, "a Drop row is not food-annotated")
end

tests["non_food_item_is_nil"] = function()
    return Assert.isTrue(F.of({ category = "eat", item = { getName = function() return "Rock" end } }) == nil,
        "an item with no getHungChange is not food")
end

tests["empty_item_no_hunger_is_nil"] = function()
    return Assert.isTrue(F.of(eatCmd(food(0, 0), 1)) == nil, "a depleted item (0 hunger) annotates to nil")
end

tests["caches_on_command"] = function()
    local c = eatCmd(food(0.5, 0.5), 1)
    F.of(c)
    return Assert.notNil(c._food, "result is cached on the command (_food)")
end

return tests
