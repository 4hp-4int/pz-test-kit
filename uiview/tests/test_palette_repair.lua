--[[ pal_repair — noun-first repair. Re-frames PZ's method-first "Fix With X"
     recipes as "Repair <your damaged item>" with the methods as a ranked family.
     isConditionRepair is validated against the REAL repair recipes in the corpus
     (RecipeDB.installReal); collect is driven with CraftMock + a damaged item. ]]
local Assert    = PZTestKit.Assert
local CraftMock = require "UIView/CraftMock"
local RecipeDB  = require "UIView/RecipeDB"
require "palette/pal_craft"
require "palette/pal_repair"
local SP = _G.SaucePalette
local RP = SP.Repair

local tests = {}

tests["isConditionRepair_matches_real_fix_recipes"] = function()
    local recipes = RecipeDB.installReal()
    local byName = {}
    for _, r in ipairs(recipes) do byName[r:getName()] = r end
    local epoxy = byName["FixWithEpoxy"]
    local tape  = byName["FixWithDuctTape"]
    local saw   = byName["DismantleLongImplement"]   -- a real non-repair recipe
    RP._isRep = nil
    local isEpoxy = epoxy and RP.isConditionRepair(epoxy)
    local isTape  = tape  and RP.isConditionRepair(tape)
    local isSaw   = saw   and RP.isConditionRepair(saw)
    RecipeDB.restore()
    if not Assert.isTrue(isEpoxy == true, "FixWithEpoxy is a condition-repair (has a repairwith* subject)") then return false end
    if not Assert.isTrue(isTape == true, "FixWithDuctTape too") then return false end
    return Assert.isTrue(isSaw ~= true, "a dismantle recipe is NOT a repair")
end

tests["methodName_strips_the_fix_with_framing"] = function()
    -- recipeName reads getText(getTranslationName); the kit's getText echoes the key,
    -- so a spaced translation name exercises the strip.
    local fake = { getTranslationName = function() return "Fix With Epoxy" end,
                   getName = function() return "FixWithEpoxy" end }
    return Assert.equal(RP.methodName(fake), "Epoxy", "the family child reads the method, not 'Fix With Epoxy'")
end

tests["collect_frames_repair_per_damaged_item"] = function()
    RP._recipes = nil; RP._isRep = nil
    local axe = {
        _type = "HandWeapon",
        getCondition = function() return 3 end, getConditionMax = function() return 10 end,
        getName = function() return "Fire Axe" end, getTexture = function() return nil end,
        getFullType = function() return "Base.Axe" end,
    }
    CraftMock.install({ axe })
    RecipeDB.installReal()
    local cmds = SP.Repair.collect(0)
    RecipeDB.restore(); CraftMock.restore()
    RP._recipes = nil; RP._isRep = nil

    if not Assert.greater(#cmds, 0, "a damaged item surfaces repair methods") then return false end
    local key, defaults = nil, 0
    for _, c in ipairs(cmds) do
        if not Assert.equal(c.category, "repair", "every row is REPAIR") then return false end
        if not Assert.equal(c.familyLabel, "Repair Fire Axe", "framed by the item, not the method") then return false end
        key = key or c.familyKey
        if not Assert.equal(c.familyKey, key, "all methods share one family (the item)") then return false end
        if c.familyDefault then defaults = defaults + 1 end
    end
    if not Assert.equal(defaults, 1, "exactly one default method (the best)") then return false end
    -- the default is rank 1
    for _, c in ipairs(cmds) do
        if c.familyDefault then
            if not Assert.equal(c.familyOrder, 1, "the default sorts first (best method)") then return false end
        end
    end
    return true
end

tests["no_repair_when_nothing_is_damaged"] = function()
    RP._recipes = nil; RP._isRep = nil
    local good = {
        _type = "HandWeapon",
        getCondition = function() return 10 end, getConditionMax = function() return 10 end,
        getName = function() return "Pristine Axe" end, getTexture = function() return nil end,
        getFullType = function() return "Base.Axe" end,
    }
    CraftMock.install({ good })
    RecipeDB.installReal()
    local cmds = SP.Repair.collect(0)
    RecipeDB.restore(); CraftMock.restore()
    RP._recipes = nil; RP._isRep = nil
    return Assert.equal(#cmds, 0, "an undamaged item never offers repair")
end

return tests
