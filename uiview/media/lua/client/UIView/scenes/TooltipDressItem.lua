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
    -- promo variant: coherent ink (a real bait item) instead of the row-kind
    -- exercise fixture — same dress, same geometry machinery
    if self.ink then
        local k = self.ink
        self:drawText(k.name, 6, 6, 1, 1, 1, 1, UIFont.Small)
        for _, r in ipairs(k.rows) do
            self:drawText(r[1], 8, r[4], 0.85, 0.85, 0.85, 1, UIFont.Small)
            if r[2] then
                self:drawText(r[2], 120, r[4], r[3][1], r[3][2], r[3][3], 1, UIFont.Small)
            end
        end
        if k.bar then
            self:drawText(k.bar.label, 8, k.bar.y, 0.85, 0.85, 0.85, 1, UIFont.Small)
            self:drawRect(120, k.bar.y + 8, 120, 6, 1, k.bar.c[1], k.bar.c[2], k.bar.c[3])
        end
        if k.section then
            self:drawText(k.section.label, 8, k.section.y, 0.93, 0.86, 0.70, 1, UIFont.Small)
            for _, r in ipairs(k.section.rows) do
                self:drawText("  " .. r[1], 8, r[4], 1, 1, 1, 1, UIFont.Small)
                self:drawText(r[2], 120, r[4], r[3][1], r[3][2], r[3][3], 1, UIFont.Small)
            end
        end
        if self.geom then
            local SIR = _G.SauceInvRender
            SIR.TTDress.ornaments(self, tooltipShim(self), self.geom, "item",
                self.accent)
        end
        return
    end
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
    if self.geom then
        -- the freshness bar: label + vanilla's FLAT progress rect, which the
        -- gauge (ornaments, below) must repaint completely
        self:drawText("Freshness", 8, 106, 0.85, 0.85, 0.85, 1, UIFont.Small)
        self:drawRect(120, 114, 120, 6, 1, 0.2, 0.8, 0.3)
        -- the sectioned block (SauceTooltips' bait list shape): cream
        -- section label, then indented rows — the ornaments hook rules them
        self:drawText("ATTRACTS", 8, 142, 0.93, 0.86, 0.70, 1, UIFont.Small)
        self:drawText("  Rat",    8, 160, 1, 1, 1, 1, UIFont.Small)
        self:drawText("High",   120, 160, 0.3, 0.9, 0.4, 1, UIFont.Small)
        self:drawText("  Rabbit", 8, 178, 1, 1, 1, 1, UIFont.Small)
        self:drawText("Medium", 120, 178, 0.9, 0.8, 0.3, 1, UIFont.Small)
        -- in-game TooltipLib invokes ornaments at the END of the real pass
        -- (after all layout ink) — mirror that order here
        local SIR = _G.SauceInvRender
        SIR.TTDress.ornaments(self, tooltipShim(self), self.geom, "item",
            self.accent)
    end
end

-- accent = optional {r,g,b,a} from TooltipLib's accent channel: the rail
-- takes the item's colour (tinted chip enamel); nil = the cherry wincap.
function TooltipDressItem.build(accent)
    local card = CardPanel:new(24, 24)
    card.accent = accent
    return card
end

-- The ruled card: same dress, taller, with a section + kv rows and the
-- geometry TooltipLib would compute for them (labelW/valueW measured the
-- same way the Java layout measures its items).
function TooltipDressItem.buildSectioned(accent)
    local card = CardPanel:new(24, 24)
    card.accent = accent
    card:setHeight(208)
    local tm = getTextManager()
    local function lw(s) return tm:MeasureStringX(UIFont.Small, s) end
    local VRX = 240   -- value column right edge (constant column, like Java)
    local function kv(y, label)
        return { y = y, h = 18, kind = "kv",
                 labelW = lw(label), valueW = VRX - 120 }
    end
    card.geom = {
        left = 8, startY = 34, lineSpacing = 18, width = W,
        top = 34, endY = 196,   -- the ruling grid (feint ledger lines)
        midX = 120, valueRightX = VRX, barH = 6,
        rows = {
            kv(34, "Type"), kv(52, "Condition"), kv(70, "Weight"),
            kv(88, "Damage"),
            { y = 106, h = 18, kind = "bar", labelW = lw("Freshness"),
              valueW = 0, fraction = 0.62, barColor = { 0.2, 0.8, 0.3, 1 } },
            -- a provider divider: TooltipLib suppresses its flat bar while
            -- the ornaments hook is active; the skin draws the dotted rule
            { y = 124, h = 18, kind = "rule", fraction = 1 },
            { y = 142, h = 18, kind = "label", labelW = lw("ATTRACTS") },
            kv(160, "  Rat"), kv(178, "  Rabbit"),
        },
        sections = {
            { y = 142, h = 18, label = "ATTRACTS", labelW = lw("ATTRACTS"),
              rowIndex = 7 },
        },
    }
    return card
end

-- PROMO card: a COHERENT item (Cabbage — real trap bait, so the ATTRACTS
-- section is true) for marketing shots. Same dress + geometry machinery as
-- buildSectioned; only the ink is curated. (The fixture card above shows a
-- frying pan that attracts rats — great row-kind coverage, nonsense promo.)
function TooltipDressItem.buildPromo(accent)
    local card = CardPanel:new(24, 24)
    card.accent = accent
    card:setHeight(208)
    local tm = getTextManager()
    local function lw(s) return tm:MeasureStringX(UIFont.Small, s) end
    local VRX = 240
    local function kv(y, label)
        return { y = y, h = 18, kind = "kv",
                 labelW = lw(label), valueW = VRX - 120 }
    end
    card.ink = {
        name = "Cabbage",
        rows = {
            { "Type",   "Food", { 1, 1, 1 }, 34 },
            { "Hunger", "-19",  { 0.2, 0.9, 0.2 }, 52 },
            { "Weight", "0.5",  { 1, 1, 1 }, 70 },
        },
        bar = { label = "Freshness", y = 88, c = { 0.2, 0.8, 0.3 } },
        section = {
            label = "ATTRACTS", y = 124,
            rows = {
                { "Rabbit", "High",   { 0.3, 0.9, 0.4 }, 142 },
                { "Rat",    "Medium", { 0.9, 0.8, 0.3 }, 160 },
            },
        },
    }
    card.geom = {
        left = 8, startY = 34, lineSpacing = 18, width = W,
        top = 34, endY = 178,
        midX = 120, valueRightX = VRX, barH = 6,
        rows = {
            kv(34, "Type"), kv(52, "Hunger"), kv(70, "Weight"),
            { y = 88, h = 18, kind = "bar", labelW = lw("Freshness"),
              valueW = 0, fraction = 0.78, barColor = { 0.2, 0.8, 0.3, 1 } },
            { y = 106, h = 18, kind = "rule", fraction = 1 },
            { y = 124, h = 18, kind = "label", labelW = lw("ATTRACTS") },
            kv(142, "  Rabbit"), kv(160, "  Rat"),
        },
        sections = {
            { y = 124, h = 18, label = "ATTRACTS", labelW = lw("ATTRACTS"),
              rowIndex = 6 },
        },
    }
    return card
end

return TooltipDressItem
