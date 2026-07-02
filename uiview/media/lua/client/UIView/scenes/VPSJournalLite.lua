--[[
    UIView - Morrison's Field Journal, JOURNAL-LITE concept
    =======================================================
    The contrast piece to VPSJournal's full leather-and-paper book: modern,
    flat, typography-led chrome that still reads "journal" through hints —
    faint grain on the content card, a hand-inked teal accent underline,
    the same ink palette. One cream, one teal, warm charcoal, whitespace.

    Chrome from VPSChrome.pack lite_* / ghost_btn / accent_btn assets;
    the specimen page rides chromeless on the cream card.
]]

require "UIView/UIMock"
local fm = UIView_fontMetrics
local Spec = require "UIView/scenes/VPSSpecimen"

local VPSJournalLite = {}

local W = 560
local PAD = 22

local CREAM   = { 0.88, 0.84, 0.76 }
local MUTED   = { 0.55, 0.52, 0.46 }
local TEAL    = { 0.24, 0.55, 0.48 }
local INK     = { 0.24, 0.20, 0.15 }

local function H(font) return fm(font).h end
local function measure(font, s) return math.floor(#tostring(s) * fm(font).w + 0.5) end

local function tex(name) return getTexture("vps_" .. name) end

local function nine(self, base, x, y, w, h, c, a)
    local tl = tex(base .. "_tl")
    if not tl then return false end
    a = a or 1
    local function piece(n, px, py, pw, ph)
        local t = tex(base .. "_" .. n)
        if t then self:drawTextureScaled(t, px, py, pw, ph, a, 1, 1, 1) end
    end
    piece("c", x + c, y + c, w - c * 2, h - c * 2)
    piece("tl", x, y, c, c);                 piece("tr", x + w - c, y, c, c)
    piece("bl", x, y + h - c, c, c);         piece("br", x + w - c, y + h - c, c, c)
    piece("t", x + c, y, w - c * 2, c);      piece("b", x + c, y + h - c, w - c * 2, c)
    piece("l", x, y + c, c, h - c * 2);      piece("r", x + w - c, y + c, c, h - c * 2)
    return true
end

local Journal = ISPanel:derive("VPSJournalLitePanel")

function Journal:new(x, y)
    local o = ISPanel.new(self, x, y, W, 100)
    o:setBackgroundColor(0.11, 0.10, 0.08, 1)
    o:setBorderColor(0, 0, 0, 0)

    o.kickerY = PAD
    o.titleY  = o.kickerY + math.floor(H(UIFont.Small) * 1.4)
    o.tabsY   = o.titleY + math.floor(H(UIFont.Large) * 1.5)
    o.tabH    = math.floor(H(UIFont.Small) * 1.9)
    o.cardY   = o.tabsY + o.tabH + 12

    -- specimen page rides chromeless on the cream card
    local cardPad = 14
    local page = Spec.Page:new(PAD + cardPad, o.cardY + cardPad, Spec.MODEL)
    page.width = W - (PAD + cardPad) * 2
    page.height = page:measure()
    page.chromeless = true
    page.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    page.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    page:initialise()
    o.page = page
    o.cardPad = cardPad
    o.cardH = page.height + cardPad * 2

    o.buttonsY = o.cardY + o.cardH + 14
    o.btnH = math.floor(H(UIFont.Small) * 2.3)
    o.height = o.buttonsY + o.btnH + PAD
    return o
end

function Journal:initialise()
    ISPanel.initialise(self)
    self:addChild(self.page)
end

function Journal:prerender()
    -- rounded charcoal panel; flat rect fallback
    if not nine(self, "lite_panel", 0, 0, self.width, self.height, 20) then
        self:drawRect(0, 0, self.width, self.height, 1, 0.11, 0.10, 0.08)
    end
    -- cream content card UNDER the page child (prerender runs before children)
    if not nine(self, "lite_card", PAD, self.cardY, self.width - PAD * 2, self.cardH, 14) then
        self:drawRect(PAD, self.cardY, self.width - PAD * 2, self.cardH, 1, 0.86, 0.82, 0.72)
    end
end

function Journal:render()
    local w = self.width

    -- ── typographic header: kicker + title + metadata ──
    self:drawText("FIELD JOURNAL", PAD, self.kickerY, TEAL[1], TEAL[2], TEAL[3], 0.95, UIFont.Small)
    self:drawText("Morrison's Notes", PAD, self.titleY, CREAM[1], CREAM[2], CREAM[3], 1, UIFont.Large)
    self:drawTextRight("water-stained / spine cracked", w - PAD,
        self.titleY + H(UIFont.Large) - H(UIFont.Small),
        MUTED[1], MUTED[2], MUTED[3], 0.9, UIFont.Small)

    -- ── underline tabs: text + inked accent bar for the active one ──
    local tabs = { { "TRAITS", false }, { "BONDS", true }, { "NOTES", false } }
    local tx = PAD
    local lblY = self.tabsY + math.floor((self.tabH - H(UIFont.Small)) / 2)
    for _, t in ipairs(tabs) do
        local tw = measure(UIFont.Small, t[1])
        if t[2] then
            self:drawText(t[1], tx, lblY, CREAM[1], CREAM[2], CREAM[3], 1, UIFont.Small)
            local ul = tex("accent_underline")
            if ul then
                self:drawTextureScaled(ul, tx - 2, self.tabsY + self.tabH - 3, tw + 4, 3, 1, 1, 1, 1)
            else
                self:drawRect(tx - 2, self.tabsY + self.tabH - 3, tw + 4, 3, 1, TEAL[1], TEAL[2], TEAL[3])
            end
        else
            self:drawText(t[1], tx, lblY, MUTED[1], MUTED[2], MUTED[3], 0.9, UIFont.Small)
        end
        tx = tx + tw + math.floor(H(UIFont.Small) * 2.2)
    end
    -- hairline under the whole tab row
    self:drawRect(PAD, self.tabsY + self.tabH, w - PAD * 2, 1, 0.14, CREAM[1], CREAM[2], CREAM[3])

    -- ── minimal scroll thumb at the card's right edge ──
    -- thumb is baked cream (for the charcoal panel); tint it walnut so it
    -- contrasts the cream card it actually rides on
    local tt, tm, tb = tex("lite_thumb_t"), tex("lite_thumb_m"), tex("lite_thumb_b")
    if tt and tm and tb then
        local sx = w - PAD - 14
        local sy = self.cardY + 12
        local sh = math.floor(self.cardH * 0.42)
        local cc = 4
        local tr, tg, tb2 = 0.35, 0.30, 0.24
        self:drawTextureScaled(tt, sx, sy, 8, cc, 0.8, tr, tg, tb2)
        self:drawTextureScaled(tm, sx, sy + cc, 8, sh - cc * 2, 0.8, tr, tg, tb2)
        self:drawTextureScaled(tb, sx, sy + sh - cc, 8, cc, 0.8, tr, tg, tb2)
    end

    -- ── footer: ghost Close + teal accent Study ──
    local function button(label, bx, bw, base, cr, cg, cb)
        if not nine(self, base, bx, self.buttonsY, bw, self.btnH, 10) then
            self:drawRectBorder(bx, self.buttonsY, bw, self.btnH, 0.6, cr, cg, cb)
        end
        self:drawTextCentre(label, bx + bw / 2,
            self.buttonsY + math.floor((self.btnH - H(UIFont.Small)) / 2),
            cr, cg, cb, 1, UIFont.Small)
    end
    button("Study Equipped", w - PAD - 160, 160, "accent_btn", CREAM[1], CREAM[2], CREAM[3])
    button("Close", w - PAD - 160 - 110 - 12, 110, "ghost_btn", MUTED[1], MUTED[2], MUTED[3])
end

function VPSJournalLite.build()
    local root = Journal:new(30, 24)
    root:initialise()
    return root
end

return VPSJournalLite
