--[[
    UIView — Extended ISUI widget mocks
    ===================================
    Additive widget coverage layered on UIMock. Each widget is an
    ISUIElement/ISPanel derive with vanilla-compatible method surfaces and a
    representative render that routes through the same draw recorder. Kept in a
    SEPARATE file from UIMock so widening coverage never collides with the
    core mock / its font table.

    Covers: ISScrollBar, ISScrollingListBox, ISComboBox, ISTickBox,
    ISTabPanel, ISModalDialog, ISCollapsableWindow.

    Fidelity goal: real mod panels that build these widgets render without
    crashing and produce a believable layout — not pixel-identical chrome.
]]

require "UIView/UIMock"
local fm = UIView_fontMetrics

local function col(r, g, b, a) return { r = r, g = g, b = b, a = a == nil and 1 or a } end

-- ============================================================================
-- ISScrollBar — thin track + thumb (used internally by scrolling widgets)
-- ============================================================================
ISScrollBar = ISUIElement:derive("ISScrollBar")

function ISScrollBar:new(parent, vertical)
    local o = ISUIElement.new(self, 0, 0, vertical and 13 or 0, vertical and 0 or 13)
    o.parentElement = parent
    o.vertical = vertical and true or false
    o.pos = 0          -- 0..1
    o.barHeight = 0.4  -- fraction of track
    return o
end

function ISScrollBar:initialise() end
function ISScrollBar:setX(x) self.x = x end
function ISScrollBar:render()
    self:drawRect(0, 0, self.width, self.height, 0.4, 0.05, 0.05, 0.05)
    if self.vertical then
        local th = math.max(16, self.height * self.barHeight)
        local ty = (self.height - th) * self.pos
        self:drawRect(2, ty, self.width - 4, th, 0.7, 0.45, 0.45, 0.5)
    else
        local tw = math.max(16, self.width * self.barHeight)
        local tx = (self.width - tw) * self.pos
        self:drawRect(tx, 2, tw, self.height - 4, 0.7, 0.45, 0.45, 0.5)
    end
end

-- ============================================================================
-- ISScrollingListBox — selectable item list with a viewport + scrollbar
-- ============================================================================
ISScrollingListBox = ISPanel:derive("ISScrollingListBox")

function ISScrollingListBox:new(x, y, width, height)
    local o = ISPanel.new(self, x, y, width, height)
    o.items = {}
    o.selected = 1
    o.itemheight = (fm(UIFont.Small).h) + 8
    o.fontHgt = fm(UIFont.Small).h
    o.font = UIFont.Small
    o.drawBorder = true
    o.backgroundColor = { r = 0.05, g = 0.05, b = 0.06, a = 0.9 }
    o.altBg = { r = 1, g = 1, b = 1, a = 0.04 }
    o.selBg = { r = 0.55, g = 0.45, b = 0.2, a = 0.35 }
    o.yScroll = 0
    return o
end

function ISScrollingListBox:initialise() ISPanel.initialise(self) end

function ISScrollingListBox:addItem(name, data)
    local item = { text = name, item = data, height = self.itemheight }
    self.items[#self.items + 1] = item
    return item
end
function ISScrollingListBox:clear() self.items = {}; self.selected = 1 end
function ISScrollingListBox:size() return #self.items end
function ISScrollingListBox:getItemHeight() return self.itemheight end
function ISScrollingListBox:setOnMouseDownFunction(target, fn) self.onmousedown = fn; self.target = target end

-- overridable per vanilla; default draws the item text
function ISScrollingListBox:doDrawItem(y, item, alt)
    local h = item.height or self.itemheight
    if self.items[self.selectedIndexBeingDrawn] == item then end
    self:drawText(item.text, 8, y + (h - self.fontHgt) / 2, 0.85, 0.85, 0.82, 1, self.font)
    return y + h
end

function ISScrollingListBox:prerender()
    ISPanel.prerender(self)
    local y = 0
    for i = 1, #self.items do
        local it = self.items[i]
        local h = it.height or self.itemheight
        if i == self.selected then
            local s = self.selBg
            self:drawRect(1, y + 1, self.width - 2, h - 1, s.a, s.r, s.g, s.b)
        elseif i % 2 == 0 then
            local a = self.altBg
            self:drawRect(1, y, self.width - 2, h, a.a, a.r, a.g, a.b)
        end
        self.selectedIndexBeingDrawn = i
        self:doDrawItem(y, it, i % 2 == 0)
        y = y + h
    end
end

function ISScrollingListBox:onMouseDown(x, y)
    local idx = math.floor(y / self.itemheight) + 1
    if self.items[idx] then
        self.selected = idx
        if self.onmousedown then self.onmousedown(self.target, self.items[idx].item) end
    end
end

-- ============================================================================
-- ISComboBox — dropdown selector
-- ============================================================================
ISComboBox = ISPanel:derive("ISComboBox")

function ISComboBox:new(x, y, width, height, target, onchange)
    local o = ISPanel.new(self, x, y, width, height)
    o.options = {}
    o.optionData = {}
    o.selected = 1
    o.target = target
    o.onChange = onchange
    o.expanded = false
    o.font = UIFont.Small
    o.borderColor = { r = 0.5, g = 0.5, b = 0.55, a = 1 }
    o.backgroundColor = { r = 0.1, g = 0.1, b = 0.12, a = 0.9 }
    return o
end

function ISComboBox:initialise() ISPanel.initialise(self) end
function ISComboBox:addOption(text, data)
    self.options[#self.options + 1] = text
    self.optionData[#self.options] = data
    return #self.options
end
function ISComboBox:getOptionText(i) return self.options[i] end
function ISComboBox:getSelectedText() return self.options[self.selected] end
function ISComboBox:select(idx) self.selected = idx end
function ISComboBox:size() return #self.options end

function ISComboBox:prerender()
    ISPanel.prerender(self)
    local txt = self.options[self.selected] or ""
    local fh = fm(self.font).h
    self:drawText(txt, 6, (self.height - fh) / 2, 0.9, 0.9, 0.85, 1, self.font)
    -- arrow box on the right
    local aw = self.height
    self:drawRect(self.width - aw, 1, aw - 1, self.height - 2, 0.6, 0.2, 0.2, 0.24)
    self:drawText("v", self.width - aw + (aw - fm(self.font).w) / 2, (self.height - fh) / 2,
        0.8, 0.8, 0.85, 1, self.font)
    if self.expanded then
        local oy = self.height
        for i = 1, #self.options do
            local ry = oy + (i - 1) * self.height
            self:drawRect(0, ry, self.width, self.height, 0.95, 0.08, 0.08, 0.1)
            if i == self.selected then
                self:drawRect(0, ry, self.width, self.height, 0.3, 0.55, 0.45, 0.2)
            end
            self:drawText(self.options[i], 6, ry + (self.height - fh) / 2, 0.85, 0.85, 0.82, 1, self.font)
        end
    end
end

-- ============================================================================
-- ISTickBox — multi-check option list
-- ============================================================================
ISTickBox = ISPanel:derive("ISTickBox")

function ISTickBox:new(x, y, width, height, name, target, onchange)
    local o = ISPanel.new(self, x, y, width, height)
    o.options = {}
    o.selected = {}
    o.font = UIFont.Small
    o.boxSize = fm(UIFont.Small).h
    o.background = false
    o.target = target
    o.onChange = onchange
    return o
end

function ISTickBox:initialise() ISPanel.initialise(self) end
function ISTickBox:addOption(text) self.options[#self.options + 1] = text; return #self.options end
function ISTickBox:setSelected(idx, val) self.selected[idx] = val and true or false end
function ISTickBox:isSelected(idx) return self.selected[idx] == true end

function ISTickBox:render()
    local bs = self.boxSize
    local fh = fm(self.font).h
    local rh = bs + 6
    for i = 1, #self.options do
        local ry = (i - 1) * rh
        self:drawRectBorder(0, ry, bs, bs, 0.9, 0.6, 0.6, 0.65)
        if self.selected[i] then
            self:drawRect(2, ry + 2, bs - 4, bs - 4, 1, 0.5, 0.85, 0.5)
        end
        self:drawText(self.options[i], bs + 8, ry + (bs - fh) / 2, 0.85, 0.85, 0.82, 1, self.font)
    end
end

-- ============================================================================
-- ISTabPanel — tab header bar + active view
-- ============================================================================
ISTabPanel = ISPanel:derive("ISTabPanel")

function ISTabPanel:new(x, y, width, height)
    local o = ISPanel.new(self, x, y, width, height)
    o.viewList = {}
    o.activeView = nil
    o.tabHeight = fm(UIFont.Small).h + 10
    o.font = UIFont.Small
    return o
end

function ISTabPanel:initialise() ISPanel.initialise(self) end
function ISTabPanel:addView(name, view)
    view.tabName = name
    self.viewList[#self.viewList + 1] = view
    if not self.activeView then self.activeView = view end
    self:addChild(view)
    view.x = 0; view.y = self.tabHeight
end
function ISTabPanel:activateView(name)
    for _, v in ipairs(self.viewList) do if v.tabName == name then self.activeView = v end end
end

function ISTabPanel:prerender()
    ISPanel.prerender(self)
    local fh = fm(self.font).h
    local x = 2
    for _, v in ipairs(self.viewList) do
        local tw = fm(self.font).w * #v.tabName + 20
        local active = (v == self.activeView)
        self:drawRect(x, 0, tw, self.tabHeight, active and 0.9 or 0.4,
            active and 0.18 or 0.08, active and 0.18 or 0.08, active and 0.22 or 0.1)
        self:drawText(v.tabName, x + 10, (self.tabHeight - fh) / 2,
            active and 0.95 or 0.6, active and 0.9 or 0.6, active and 0.7 or 0.6, 1, self.font)
        v._visibleAsTab = active
        x = x + tw + 2
    end
    -- hide inactive views so the frame driver skips them
    for _, v in ipairs(self.viewList) do
        v:setVisible(v == self.activeView)
    end
end

-- ============================================================================
-- ISModalDialog — message + yes/no buttons
-- ============================================================================
ISModalDialog = ISPanel:derive("ISModalDialog")

function ISModalDialog:new(x, y, width, height, text, yesno, target, onclick)
    local o = ISPanel.new(self, x, y, width, height)
    o.text = text or ""
    o.yesno = yesno
    o.target = target
    o.onclick = onclick
    o.font = UIFont.Small
    o.backgroundColor = { r = 0.08, g = 0.08, b = 0.1, a = 0.96 }
    o.borderColor = { r = 0.5, g = 0.45, b = 0.2, a = 1 }
    return o
end

function ISModalDialog:initialise() ISPanel.initialise(self) end
function ISModalDialog:render()
    local fh = fm(self.font).h
    self:drawTextCentre(self.text, self.width / 2, 14, 0.9, 0.9, 0.85, 1, self.font)
    local bw, bh = 80, fh + 10
    local by = self.height - bh - 8
    if self.yesno then
        self:drawRect(self.width / 2 - bw - 8, by, bw, bh, 0.85, 0.15, 0.3, 0.15)
        self:drawTextCentre("Yes", self.width / 2 - 8 - bw / 2, by + 5, 0.85, 1, 0.85, 1, self.font)
        self:drawRect(self.width / 2 + 8, by, bw, bh, 0.85, 0.3, 0.15, 0.15)
        self:drawTextCentre("No", self.width / 2 + 8 + bw / 2, by + 5, 1, 0.85, 0.85, 1, self.font)
    else
        self:drawRect(self.width / 2 - bw / 2, by, bw, bh, 0.85, 0.15, 0.2, 0.3)
        self:drawTextCentre("OK", self.width / 2, by + 5, 0.85, 0.9, 1, 1, self.font)
    end
end

-- ============================================================================
-- ISCollapsableWindow — title bar + body
-- ============================================================================
ISCollapsableWindow = ISPanel:derive("ISCollapsableWindow")

function ISCollapsableWindow:new(x, y, width, height)
    local o = ISPanel.new(self, x, y, width, height)
    o.title = ""
    o.titleBarHeight = fm(UIFont.Small).h + 8
    o.font = UIFont.Small
    o.collapsed = false
    o.resizable = true
    o.backgroundColor = { r = 0.06, g = 0.06, b = 0.07, a = 0.92 }
    o.borderColor = { r = 0.4, g = 0.4, b = 0.45, a = 1 }
    return o
end

function ISCollapsableWindow:initialise() ISPanel.initialise(self) end
function ISCollapsableWindow:setTitle(t) self.title = t or "" end

function ISCollapsableWindow:prerender()
    ISPanel.prerender(self)
    local th = self.titleBarHeight
    local fh = fm(self.font).h
    -- title bar
    self:drawRect(0, 0, self.width, th, 0.9, 0.12, 0.12, 0.15)
    self:drawRect(0, th, self.width, 1, 0.6, 0.4, 0.4, 0.45)
    self:drawTextCentre(self.title, self.width / 2, (th - fh) / 2, 0.9, 0.9, 0.85, 1, self.font)
    -- collapse + close glyphs
    self:drawText("_", 6, (th - fh) / 2, 0.7, 0.7, 0.75, 1, self.font)
    self:drawText("x", self.width - 12, (th - fh) / 2, 0.8, 0.6, 0.6, 1, self.font)
    -- resize handle
    if self.resizable then
        self:drawText(".", self.width - 8, self.height - fh, 0.5, 0.5, 0.55, 1, self.font)
    end
end

return {
    ISScrollBar = ISScrollBar,
    ISScrollingListBox = ISScrollingListBox,
    ISComboBox = ISComboBox,
    ISTickBox = ISTickBox,
    ISTabPanel = ISTabPanel,
    ISModalDialog = ISModalDialog,
    ISCollapsableWindow = ISCollapsableWindow,
}
