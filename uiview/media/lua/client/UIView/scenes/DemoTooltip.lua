--[[
    UIView — Demo scene: weapon-mastery tooltip
    ===========================================
    A representative panel built with the mock ISPanel/ISButton/ISLabel exactly
    as a real mod would: derive a panel, override render() to paint stat rows,
    a progress bar, and a couple of buttons. Renders headlessly into a display
    list. Returns build() -> root element.
]]

require "UIView/UIMock"
local fontMetrics = UIView_fontMetrics

local DemoTooltip = {}

local TooltipPanel = ISPanel:derive("MasteryTooltip")

function TooltipPanel:new(x, y)
    local o = ISPanel.new(self, x, y, 300, 196)
    o:setBackgroundColor(0.06, 0.05, 0.08, 0.92)
    o:setBorderColor(0.55, 0.35, 0.75, 1)
    o.weaponName = "Vorpal Machete"
    o.tier = "Tier III - Reaver"
    o.kills = 247
    o.nextAt = 300
    o.stats = {
        { label = "Damage",   value = "+0.42", col = { 0.5, 1.0, 0.5 } },
        { label = "Crit",     value = "+9%",   col = { 0.5, 1.0, 0.5 } },
        { label = "Speed",    value = "+0.15", col = { 0.5, 1.0, 0.5 } },
        { label = "Knockback", value = "+0.30", col = { 1.0, 0.85, 0.4 } },
    }
    return o
end

function TooltipPanel:render()
    local pad = 12
    local f = UIFont.Medium
    -- title
    self:drawText(self.weaponName, pad, 8, 0.95, 0.85, 1.0, 1, UIFont.Large)
    self:drawText(self.tier, pad, 34, 0.75, 0.6, 0.95, 1, UIFont.Small)

    -- divider
    self:drawRect(pad, 54, self.width - pad * 2, 1, 0.4, 0.5, 0.4, 0.6)

    -- stat rows
    local rowY = 64
    for _, s in ipairs(self.stats) do
        self:drawText(s.label, pad, rowY, 0.8, 0.8, 0.85, 1, UIFont.Small)
        self:drawTextRight(s.value, self.width - pad, rowY,
            s.col[1], s.col[2], s.col[3], 1, UIFont.Small)
        rowY = rowY + 18
    end

    -- progress bar toward next tier
    local barX, barW = pad, self.width - pad * 2
    local barY, barH = rowY + 6, 12
    self:drawRect(barX, barY, barW, barH, 0.6, 0.1, 0.1, 0.12)
    local frac = self.kills / self.nextAt
    self:drawRect(barX, barY, barW * frac, barH, 0.9, 0.6, 0.3, 0.85)
    self:drawRectBorder(barX, barY, barW, barH, 1, 0.5, 0.4, 0.6)
    self:drawTextCentre(self.kills .. " / " .. self.nextAt .. " kills",
        self.width / 2, barY + barH + 4, 0.85, 0.85, 0.9, 1, UIFont.Small)
end

function DemoTooltip.build()
    local root = TooltipPanel:new(60, 40)
    root:initialise()

    -- a couple of interactive buttons docked at the bottom
    local btnY = root.height - 30
    local inspect = ISButton:new(12, btnY, 130, 22, "Inspect", root, function(t, btn)
        btn.title = "Inspected!"
    end)
    inspect.font = UIFont.Small
    root:addChild(inspect)

    local reset = ISButton:new(root.width - 12 - 130, btnY, 130, 22, "Reset Mastery", root, function() end)
    reset.font = UIFont.Small
    root:addChild(reset)

    root._buttons = { inspect = inspect, reset = reset }
    return root
end

return DemoTooltip
