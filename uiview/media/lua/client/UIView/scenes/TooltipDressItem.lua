--[[
    UIView — Scene: an ITEM tooltip card wearing SIR's dress
    ========================================================
    The item surface is what players see most, but the real ISToolTipInv /
    ObjectTooltip pipeline is Java — so this scene drives sauce-invrender's
    REAL D.draw (the exact callback TooltipLib invokes) against an
    ObjectTooltip-shaped shim that forwards its Java-style draw calls
    (DrawTextureScaledColor: colour args trail, alpha last) into the mock
    panel, then paints representative vanilla-style tooltip ink on top.
    Locks the card's composition: kraft ledger body + cherry title rail.

    Returns build() -> the panel.
]]

require "UIView/UIMock"
require "sir_ttdress"

local TooltipDressItem = {}

local W, H = 300, 150

local CardPanel = ISPanel:derive("SIRItemTooltipCard")

function CardPanel:new(x, y)
    local o = ISPanel.new(self, x, y, W, H)
    o:setBackgroundColor(0, 0, 0, 0)   -- the dress paints the card
    o:setBorderColor(0, 0, 0, 0)
    return o
end

-- ObjectTooltip-shaped shim over the panel (the surface D.draw sees in-game)
local function tooltipShim(panel)
    local t = { padTop = 5 }
    function t.isMeasureOnly() return false end
    function t.getLineSpacing() return 18 end
    function t.getWidth() return panel.width end
    function t.getHeight() return panel.height end
    function t.DrawTextureScaledColor(_, tex, x, y, w, h, r, g, b, a)
        panel:drawTextureScaled(tex, x, y, w, h, a or 1, r or 1, g or 1, b or 1)
    end
    return t
end

function CardPanel:prerender()
    local SIR = _G.SauceInvRender
    SIR.TTDress.draw(self, tooltipShim(self), self.width, self.height, "item",
        self.accent)
end

function CardPanel:render()
    -- representative vanilla tooltip ink (white name, pale labels, values)
    self:drawText("Frying Pan", 6, 6, 1, 1, 1, 1, UIFont.Small)
    local rows = {
        { "Type",      "Weapon",   { 1, 1, 1 } },
        { "Condition", "8/10",     { 0.2, 0.9, 0.2 } },
        { "Weight",    "2.0",      { 1, 1, 1 } },
        { "Damage",    "0.5-1.0",  { 1, 1, 0.8 } },
    }
    local y = 34
    for _, r in ipairs(rows) do
        self:drawText(r[1], 8, y, 0.85, 0.85, 0.85, 1, UIFont.Small)
        self:drawText(r[2], 120, y, r[3][1], r[3][2], r[3][3], 1, UIFont.Small)
        y = y + 18
    end
end

-- accent = optional {r,g,b,a} from TooltipLib's accent channel: the rail
-- takes the item's colour (tinted chip enamel); nil = the cherry wincap.
function TooltipDressItem.build(accent)
    local card = CardPanel:new(24, 24)
    card.accent = accent
    return card
end

return TooltipDressItem
