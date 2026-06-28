--[[
    UIView — widget kitchen-sink render tests
    =========================================
    Renders every extended widget and asserts each painted, then emits the
    display list for the viewer + snapshot framework.
]]

local Assert   = PZTestKit.Assert
local Recorder = require "UIView/Recorder"
local Render   = require "UIView/Render"
local Input    = require "UIView/Input"
local Widgets  = require "UIView/scenes/Widgets"

do
    local root = Widgets.build()
    Render.emit(root, 800, 510, "widgets")
end

local function findText(substr)
    for _, op in ipairs(Recorder.ops) do
        if op.op == "text" and tostring(op.str):find(substr, 1, true) then return op end
    end
    return nil
end

local tests = {}

tests["all_widgets_paint_something"] = function()
    local root = Widgets.build()
    Render.frame(root, 800, 510)
    return Assert.greater(#Recorder.ops, 20, "kitchen sink produced a populated display list")
end

tests["list_items_render"] = function()
    local root = Widgets.build()
    Render.frame(root, 800, 510)
    return Assert.notNil(findText("Foraging"), "scrolling list item painted")
end

tests["combo_shows_selected_option"] = function()
    local root = Widgets.build()
    Render.frame(root, 800, 510)
    return Assert.notNil(findText("By Category"), "combo selected option painted")
end

tests["active_tab_view_renders_inactive_hidden"] = function()
    local root = Widgets.build()
    Render.frame(root, 800, 510)
    if not Assert.notNil(findText("Inventory view"), "active tab view content painted") then return false end
    return Assert.isNil(findText("Crafting view"), "inactive tab view content hidden")
end

tests["list_click_selects_item"] = function()
    local root = Widgets.build()
    local list = root._widgets.list
    -- click the 2nd row (Cooking)
    local sx = list:getAbsoluteX() + 20
    local sy = list:getAbsoluteY() + list.itemheight + 4
    Input.click(root, sx, sy)
    return Assert.equal(list.selected, 2, "clicking row 2 selects it")
end

return tests
