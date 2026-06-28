--[[
    UIView — SaucePalette render + drive tests
    ==========================================
    Renders sauce-invrender's REAL SaucePaletteUI headlessly and asserts its
    grouping/filtering logic, then emits the display list for the viewer.
]]

local Assert    = PZTestKit.Assert
local Recorder  = require "UIView/Recorder"
local Render    = require "UIView/Render"
local Input     = require "UIView/Input"
local Palette   = require "UIView/scenes/SaucePalette"

-- Emit zero-state once at load for the viewer.
do
    local root = Palette.build("")
    Render.emit(root, 1280, 800, "palette")
end

local function findText(substr)
    for _, op in ipairs(Recorder.ops) do
        if op.op == "text" and tostring(op.str):find(substr, 1, true) then return op end
    end
    return nil
end

local tests = {}

tests["palette_builds_rows_from_commands"] = function()
    local root = Palette.build("")
    return Assert.greater(#root.rows, 0, "row list populated from fixture commands")
end

tests["duplicate_verb_collapses_into_group"] = function()
    local root = Palette.build("")
    local group = nil
    for _, r in ipairs(root.rows) do
        if r.kind == "group" and r.group.label == "Equip Primary" then group = r.group end
    end
    if not Assert.notNil(group, "Equip Primary group exists") then return false end
    return Assert.equal(#group.cmds, 3, "group holds all 3 equip commands")
end

tests["renders_chips_and_labels"] = function()
    local root = Palette.build("")
    Render.frame(root, 1280, 800)
    if not Assert.notNil(findText("CRAFT"), "CRAFT chip painted") then return false end
    return Assert.notNil(findText("Crude Bandage"), "craft row label painted")
end

tests["typing_filters_the_list"] = function()
    local root = Palette.build("water")
    -- only the Drink Water command should survive the fuzzy filter
    local labels = {}
    for _, r in ipairs(root.rows) do
        if r.cmd then labels[r.cmd.label] = true end
    end
    if not Assert.isTrue(labels["Drink Water"] == true, "Drink Water matches 'water'") then return false end
    return Assert.isTrue(labels["Open Door"] == nil, "Open Door filtered out by 'water'")
end

tests["enter_expands_group"] = function()
    local root = Palette.build("")
    -- find + select the Equip group, then runSel() to toggle expand
    for i, r in ipairs(root.rows) do
        if r.kind == "group" and r.group.label == "Equip Primary" then root.sel = i break end
    end
    root:runSel()
    return Assert.isTrue(root.rows[root.sel] ~= nil and
        (function() for _, r in ipairs(root.rows) do if r.kind == "child" then return true end end return false end)(),
        "child rows appear after expanding group")
end

return tests
