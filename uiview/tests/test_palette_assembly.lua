--[[ pal_assembly — noun-first dismantle & assemble. Re-frames PZ's generic mapper
     recipes ("Dismantle Long Implement") per the item you hold: dismantle names by
     the weapon you break down, assemble by the weapon you build. isAssemblyMapper is
     validated against the REAL recipes (RecipeDB.installReal). ]]
local Assert    = PZTestKit.Assert
local CraftMock = require "UIView/CraftMock"
local RecipeDB  = require "UIView/RecipeDB"
require "palette/pal_craft"
require "palette/pal_assembly"
local SP = _G.SaucePalette
local AS = SP.Assembly

local function resetCaches() AS._recipes = nil; AS._is = nil end

local tests = {}

tests["isAssemblyMapper_matches_real_recipes"] = function()
    local recipes = RecipeDB.installReal()
    local byName = {}; for _, r in ipairs(recipes) do byName[r:getName()] = r end
    resetCaches()
    local dis = byName["DismantleLongImplement"] and AS.isAssemblyMapper(byName["DismantleLongImplement"])
    local asm = byName["AssembleLongImplement"] and AS.isAssemblyMapper(byName["AssembleLongImplement"])
    local box = byName["OpenBox100"] and AS.isAssemblyMapper(byName["OpenBox100"])  -- Packing, not Assembly
    RecipeDB.restore(); resetCaches()
    if not Assert.isTrue(dis == true, "DismantleLongImplement is a mapper-driven Assembly recipe") then return false end
    if not Assert.isTrue(asm == true, "AssembleLongImplement too") then return false end
    return Assert.isTrue(box ~= true, "a Packing recipe is NOT assembly")
end

tests["dismantle_names_by_the_held_weapon"] = function()
    resetCaches()
    local axe = { _type = "HandWeapon", getName = function() return "Fire Axe" end,
                  getTexture = function() return nil end, getFullType = function() return "Base.Axe" end }
    CraftMock.install({ axe }); RecipeDB.installReal()
    local cmds = SP.Assembly.collect(0)
    RecipeDB.restore(); CraftMock.restore(); resetCaches()
    local found
    for _, c in ipairs(cmds) do if c.label == "Dismantle Fire Axe" then found = c end end
    if not Assert.notNil(found, "a held weapon surfaces 'Dismantle <weapon>'") then return false end
    if not Assert.equal(found.category, "assembly", "wears the ASSEMBLE chip") then return false end
    return Assert.equal(type(found.run), "function", "and is runnable")
end

tests["assemble_names_by_the_built_item"] = function()
    resetCaches()
    local head = { _type = "Item", getName = function() return "Fire Axe Head" end,
                   getTexture = function() return nil end, getFullType = function() return "Base.FireAxeHead" end }
    CraftMock.install({ head }); RecipeDB.installReal()
    local cmds = SP.Assembly.collect(0)
    RecipeDB.restore(); CraftMock.restore(); resetCaches()
    local found
    for _, c in ipairs(cmds) do if c.label and c.label:find("^Assemble ", 1) then found = c end end
    if not Assert.notNil(found, "a held weapon HEAD surfaces an 'Assemble <item>' row") then return false end
    return Assert.equal(found.category, "assembly", "ASSEMBLE chip")
end

tests["dismantle_is_discoverable_without_the_tool"] = function()
    resetCaches()
    local axe = { _type = "HandWeapon", getName = function() return "Fire Axe" end,
                  getTexture = function() return nil end, getFullType = function() return "Base.Axe" end }
    CraftMock.install({ axe }); CraftMock.canCraft = false     -- hold the weapon, lack the hammer
    RecipeDB.installReal()
    local cmds = SP.Assembly.collect(0)
    CraftMock.canCraft = nil
    RecipeDB.restore(); CraftMock.restore(); resetCaches()
    local found
    for _, c in ipairs(cmds) do if c.label == "Dismantle Fire Axe" then found = c end end
    if not Assert.notNil(found, "a held weapon shows 'Dismantle' even without the tool") then return false end
    if not Assert.equal(found.runnable, false, "blocked when you lack the hammer") then return false end
    return Assert.notNil(found.blockReason, "and says what it needs")
end

tests["nothing_to_assemble_with_an_empty_bag"] = function()
    resetCaches()
    CraftMock.install({}); RecipeDB.installReal()
    local cmds = SP.Assembly.collect(0)
    RecipeDB.restore(); CraftMock.restore(); resetCaches()
    return Assert.equal(#cmds, 0, "no held parts -> no assembly rows")
end

return tests
