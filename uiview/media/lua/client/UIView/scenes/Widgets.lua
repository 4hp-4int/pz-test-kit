--[[
    UIView — Scene: widget kitchen sink
    ===================================
    One of each extended widget, laid out in a host panel, so coverage is
    visible at a glance and snapshot-tested. Proves the widgets render + nest.
]]

require "UIView/UIWidgets"
UIView_setScreen(1280, 800)

local Widgets = {}

local function labelView(text)
    local v = ISPanel:new(0, 0, 420, 150)
    v.background = false
    v.render = function(self)
        self:drawText(text, 12, 12, 0.85, 0.85, 0.8, 1, UIFont.Small)
    end
    return v
end

function Widgets.build()
    local root = ISPanel:new(20, 20, 760, 470)
    root:setBackgroundColor(0.04, 0.04, 0.05, 0.95)
    root:setBorderColor(0.4, 0.4, 0.5, 1)
    root:initialise()

    -- collapsable window
    local win = ISCollapsableWindow:new(12, 12, 230, 200)
    win:setTitle("Character")
    win:initialise()
    root:addChild(win)

    -- scrolling list
    local list = ISScrollingListBox:new(254, 12, 220, 200)
    list:initialise()
    list:addItem("Carpentry      4")
    list:addItem("Cooking        2")
    list:addItem("Foraging       6")
    list:addItem("Mechanics      1")
    list:addItem("Tailoring      3")
    list.selected = 3
    root:addChild(list)

    -- combo box
    local combo = ISComboBox:new(486, 12, 200, 26)
    combo:initialise()
    combo:addOption("Suggested")
    combo:addOption("By Category")
    combo:addOption("Recently Used")
    combo.selected = 2
    root:addChild(combo)

    -- tick box
    local ticks = ISTickBox:new(486, 50, 200, 110)
    ticks:initialise()
    ticks:addOption("Show icons")
    ticks:addOption("Group verbs")
    ticks:addOption("Needs ranking")
    ticks:setSelected(1, true)
    ticks:setSelected(3, true)
    root:addChild(ticks)

    -- tab panel with two views
    local tabs = ISTabPanel:new(12, 224, 460, 230)
    tabs:initialise()
    tabs:addView("Inventory", labelView("Inventory view contents render here"))
    tabs:addView("Crafting", labelView("Crafting view contents render here"))
    tabs:activateView("Inventory")
    root:addChild(tabs)

    -- modal dialog
    local modal = ISModalDialog:new(486, 224, 262, 120, "Reset all mastery progress?", true)
    modal:initialise()
    root:addChild(modal)

    root._widgets = { win = win, list = list, combo = combo, ticks = ticks, tabs = tabs, modal = modal }
    return root
end

return Widgets
