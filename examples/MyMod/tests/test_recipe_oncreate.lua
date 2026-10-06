--[[
    Recipe OnCreate runs (2026-10-06). Every recipe with an xpAward died in
    CraftRecipe.addXP: it reaches LuaManager.GlobalObject.getCore(), and the
    real GlobalObject could not initialise beside the kit's stub LuaManager
    (IllegalAccessError: not a nest member). Kahlua swallowed the Error, so
    the craft consumed its inputs, created its outputs and returned before
    vanilla ISHandcraftAction:performRecipe reached luaCallOnCreate: no
    repair, no sharpening, no smelting OnCreate ever ran here. The stub now
    carries its own GlobalObject (stubs/zombie/Lua/LuaManager.java).

    genericBetterFixing (FixWithDuctTape's OnCreate) increments the item's
    repair count before its fail roll, so the count proves OnCreate ran
    whatever the roll did.
]]

if not (PZEngine and PZEngine.available()) then return {} end
local Assert = PZTestKit.Assert
local BP = PZTestKit.Blueprints

local tests = {}

tests["a_repair_recipe_runs_its_oncreate"] = function()
    BP.loadWorkbench()
    local r = WB.tools.craft({ recipe = "FixWithDuctTape",
        items = { { type = "Base.Axe", steps = { { addon = "core", action = "setCondition", params = { condition = 5 } } } },
                  { type = "Base.DuctTape", count = 2 } } })
    if not Assert.isTrue(r.ok == true, "the craft ran: " .. tostring(r.error)) then return false end
    local axe
    for _, it in ipairs(r.kept or {}) do if it.fullType == "Base.Axe" then axe = it end end
    if not Assert.notNil(axe, "the axe is kept") then return false end
    local item = WB.deref and WB.deref(axe.ref)
    if not Assert.notNil(item, "the live axe") then return false end
    return Assert.equal(item:getHaveBeenRepaired(), 1, "genericBetterFixing ran (repair count 0 -> 1)")
end

return tests
