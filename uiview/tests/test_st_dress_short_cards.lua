--[[
    UIView — SauceTooltips' skin on SHORT cards (junk items)
    ========================================================
    The title band (the accent rail under the item name) used to need a card
    twice its own height (Dress.lua `h >= capH * 2`, ~50 px), so every one-row
    card -- an ID card, a Rag, most junk (41 px) -- wore the body with no band
    (2026-10-08). Now it needs the name row and one row under it. Emits "stdressshort":
    four cards side by side, shortest first, and asserts every one wears a band.
]]

local Assert   = PZTestKit.Assert
local Recorder = require "UIView/Recorder"
local Render   = require "UIView/Render"
require "UIView/UIMock"
require "SauceTooltips/Dress"
local D = _G.SauceTooltips_Dress

local PAD, LS = 5, 18
local CREAM = { 1.0, 1.0, 0.8 }

-- an ObjectTooltip-shaped shim over a panel (Dress.lua draws through it)
local function shimOver(panel, pad)
    local t = { padTop = pad or PAD }
    function t.getLineSpacing() return LS end
    function t.DrawTextureScaledColor(_, tex, x, y, w, h, r, g, b, a)
        panel:drawTextureScaled(tex, x, y, w, h, a or 1, r or 1, g or 1, b or 1)
    end
    return t
end

local VPS_BLUE = { 0.33, 0.62, 0.95, 1.0 }

-- name + rows, as the card draws them (the skin first, then the text on it)
local CARDS = {
    -- the ID card exactly as the engine draws it (SousVide, 2026-10-08): 188 x 41,
    -- padTop 3 (half a character of the tooltip font), rows 18 apart
    { name = "ID Card",             w = 188, pad = 3, h = 41, rows = { { "Encumbrance:", "0.1" } } },
    { name = "Rag",                 w = 170, rows = { { "Encumbrance:", "0.1" } } },
    { name = "Nails",               w = 170, rows = { { "Encumbrance:", "0.01" }, { "Count:", "34" } }, accent = VPS_BLUE },
    { name = "Screwdriver",         w = 200, rows = { { "Encumbrance:", "0.5" }, { "Condition:", "8/10" }, { "Damage:", "0.3" } }, accent = VPS_BLUE },
    { name = "Deadly Firefighter Axe", w = 250, rows = { { "Encumbrance:", "3.0" }, { "Sharpness:", "90%" }, { "Head Condition:", "12/13" },
                                                          { "Damage:", "1.2 - 2.0" }, { "Mark: Deadly", "" } }, accent = VPS_BLUE },
}

local function cardHeight(c) return c.h or (PAD + LS * (1 + #c.rows) + PAD) end

local Card = ISPanel:derive("STShortCard")
function Card:prerender() end
function Card:render()
    local c = self.card
    local pad = c.pad or PAD
    D.draw(self, shimOver(self, pad), self.width, self.height, "item", c.accent)
    self:drawText(c.name, PAD, pad, CREAM[1], CREAM[2], CREAM[3], 1, UIFont.Small)
    for i, r in ipairs(c.rows) do
        local y = pad + LS * i
        self:drawText(r[1], PAD, y, 1, 1, 0.8, 1, UIFont.Small)
        if r[2] ~= "" then self:drawTextRight(r[2], self.width - PAD, y, 1, 1, 1, 1, UIFont.Small) end
    end
end

local function build()
    D._tripped = false
    local root = ISPanel:new(0, 0, 10, 10)
    root.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    root.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    local x, tallest = 0, 0
    for _, c in ipairs(CARDS) do
        local h = cardHeight(c)
        local p = ISPanel.new(Card, x, 0, c.w, h)
        p.card = c
        root:addChild(p)
        x = x + c.w + 16
        tallest = math.max(tallest, h)
    end
    root:setWidth(x - 16)
    root:setHeight(tallest)
    return root
end

do
    local root = build()
    Render.emit(root, root:getWidth() + 48, root:getHeight() + 48, "stdressshort")
end

local tests = {}

-- every card wears a title band: the wincap (no accent) or the tinted chip
tests["every_short_card_wears_a_title_band"] = function()
    local root = build()
    local ok = true
    -- and a name-only card never does (the band would be the whole card)
    for i, c in ipairs(CARDS) do
        Recorder.ops = {}
        local only = ISPanel:new(0, 0, 10, 10)
        local p = ISPanel.new(Card, 0, 0, c.w, cardHeight(c))
        p.card = c
        only:addChild(p)
        only:setWidth(c.w); only:setHeight(cardHeight(c))
        Render.frame(only, c.w + 20, cardHeight(c) + 20)
        local band = false
        for _, op in ipairs(Recorder.ops) do
            local n = tostring(op.name or "")
            if op.op == "texture" and (n:find("^st_wincap_") or n:find("^st_chip_")) then band = true end
        end
        ok = Assert.isTrue(band, c.name .. " (" .. cardHeight(c) .. " px tall) wears a title band") and ok
    end
    Recorder.ops = {}
    local bare = { name = "Mystery", w = 150, pad = 3, h = 23, rows = {} }
    local only = ISPanel:new(0, 0, 150, 23)
    local p = ISPanel.new(Card, 0, 0, 150, 23)
    p.card = bare
    only:addChild(p)
    Render.frame(only, 170, 43)
    local band = false
    for _, op in ipairs(Recorder.ops) do
        local n = tostring(op.name or "")
        if op.op == "texture" and (n:find("^st_wincap_") or n:find("^st_chip_")) then band = true end
    end
    return Assert.isTrue(not band, "a name-only card (23 px) wears no band") and ok
end

return tests
