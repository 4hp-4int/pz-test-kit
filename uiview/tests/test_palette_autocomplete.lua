--[[ pal_ui autocomplete ghost — when the typed text is a case-insensitive PREFIX
     of the selected row's label, the untyped remainder is offered as inline ghost
     text (Tab accepts it). Skipped for fuzzy/substring matches and while a
     quantity prefix is active. ]]
local Assert = PZTestKit.Assert
local States = require "UIView/scenes/PaletteStates"

local tests = {}

tests["ghost_completes_prefix_match"] = function()
    local root = States.build({ query = "forge" })   -- only "Forge Machete" matches, by prefix
    root:computeGhost()
    if not Assert.equal(root._ghostFull, "Forge Machete", "ghost full = the completed label") then return false end
    return Assert.equal(root._ghost, " Machete", "ghost = the untyped remainder")
end

tests["no_ghost_for_non_prefix_match"] = function()
    local root = States.build({ query = "mach" })     -- matches "Forge Machete" by substring, NOT prefix
    root:computeGhost()
    return Assert.isNil(root._ghostFull, "no ghost when the query isn't a label prefix")
end

tests["no_ghost_with_quantity_prefix"] = function()
    local root = States.build({ query = "5 forge" })  -- quantity active -> autocomplete suppressed
    root:computeGhost()
    return Assert.isNil(root._ghostFull, "no ghost while a quantity prefix is active")
end

return tests
