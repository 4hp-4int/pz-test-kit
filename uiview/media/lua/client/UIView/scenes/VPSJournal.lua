--[[
    UIView - Morrison's Field Journal, WHOLE-SURFACE chrome concept
    ===============================================================
    The full journal skinned from VPSChrome.pack: dark leather cover
    (leather_tile + embossed cover_* frame), stitched title rule, paper
    page-marker tabs (tab_active_* open at the bottom so it flows into the
    page), the specimen page as content, stamped-label buttons (btn_*), and
    the scroll rail skin (scroll_track / scroll_thumb).

    Draw order rides Render.walk: prerender (leather ground) -> children
    (the specimen page) -> render (cover frame, tabs, buttons ON TOP), so
    the active tab's open bottom overlaps the page frame and reads as one
    continuous sheet of paper.
]]

require "UIView/UIMock"
local fm = UIView_fontMetrics
local Spec = require "UIView/scenes/VPSSpecimen"

local VPSJournal = {}

local W = 560
local PAD = 15

local INK        = { 0.24, 0.20, 0.15 }
local INK_ON_DIM = { 0.20, 0.17, 0.12 }
local GOLD       = { 0.80, 0.66, 0.36 }
local GOLD_DIM   = { 0.60, 0.51, 0.34 }
local THREAD     = { 0.62, 0.52, 0.34 }

local function H(font) return fm(font).h end
local function measure(font, s) return math.floor(#tostring(s) * fm(font).w + 0.5) end

local Journal = ISPanel:derive("VPSJournalPanel")

local function tex(name) return getTexture("vps_" .. name) end

--- draw a 9-slice frame (corner pieces authored at 2x; c = on-screen corner)
local function nine(self, base, x, y, w, h, c, withCentre)
    local tl = tex(base .. "_tl")
    if not tl then return false end
    local function piece(n, px, py, pw, ph)
        local t = tex(base .. "_" .. n)
        if t then self:drawTextureScaled(t, px, py, pw, ph, 1, 1, 1, 1) end
    end
    if withCentre then piece("c", x + c, y + c, w - c * 2, h - c * 2) end
    piece("tl", x, y, c, c);                 piece("tr", x + w - c, y, c, c)
    piece("bl", x, y + h - c, c, c);         piece("br", x + w - c, y + h - c, c, c)
    piece("t", x + c, y, w - c * 2, c);      piece("b", x + c, y + h - c, w - c * 2, c)
    piece("l", x, y + c, c, h - c * 2);      piece("r", x + w - c, y + c, c, h - c * 2)
    return true
end

--- draw a 3-slice horizontal strip (tabs)
local function three(self, base, x, y, w, h, c)
    local l = tex(base .. "_l")
    if not l then return false end
    self:drawTextureScaled(l, x, y, c, h, 1, 1, 1, 1)
    local m = tex(base .. "_m")
    if m then self:drawTextureScaled(m, x + c, y, w - c * 2, h, 1, 1, 1, 1) end
    local r = tex(base .. "_r")
    if r then self:drawTextureScaled(r, x + w - c, y, c, h, 1, 1, 1, 1) end
    return true
end

function Journal:new(x, y)
    local o = ISPanel.new(self, x, y, W, 100)
    o:setBackgroundColor(0.14, 0.10, 0.06, 1)
    o:setBorderColor(0.07, 0.05, 0.03, 1)

    -- header metrics (computed once; render reads them)
    o.titleY = PAD
    o.condY  = o.titleY + math.floor(H(UIFont.Large) * 1.15)
    o.stitchY = o.condY + math.floor(H(UIFont.Small) * 1.35)
    o.tabsY  = o.stitchY + 18
    o.tabH   = math.floor(H(UIFont.Small) * 2.1)

    -- the specimen page IS the content area; active tab overlaps its top
    -- frame by a few px so tab paper and page paper read as one sheet.
    local page = Spec.Page:new(PAD, o.tabsY + o.tabH - 4, Spec.MODEL)
    page.width = W - PAD * 2
    page.height = page:measure()
    page:initialise()
    o.page = page

    o.buttonsY = page.y + page.height + 10
    o.btnH = math.floor(H(UIFont.Small) * 2.2)
    o.height = o.buttonsY + o.btnH + PAD
    return o
end

function Journal:initialise()
    ISPanel.initialise(self)
    self:addChild(self.page)
end

function Journal:prerender()
    -- leather cover ground: tile, else flat walnut
    local leather = tex("leather_tile")
    if leather then
        local tile = 256
        for ix = 0, math.ceil(self.width / tile) - 1 do
            for iy = 0, math.ceil(self.height / tile) - 1 do
                self:drawTextureScaled(leather, ix * tile, iy * tile, tile, tile, 1, 1, 1, 1)
            end
        end
    else
        self:drawRect(0, 0, self.width, self.height, 1, 0.14, 0.10, 0.06)
    end
end

function Journal:render()
    local w = self.width

    -- ── letterhead: stamped title + condition + stitched rule ──
    self:drawTextCentre("MORRISON'S FIELD JOURNAL", w / 2, self.titleY,
        GOLD[1], GOLD[2], GOLD[3], 1, UIFont.Large)
    self:drawTextCentre("water-stained, the spine cracked", w / 2, self.condY,
        GOLD_DIM[1], GOLD_DIM[2], GOLD_DIM[3], 0.9, UIFont.Small)
    local st = tex("stitch_rule")
    if st then
        self:drawTextureScaled(st, PAD + 40, self.stitchY, w - (PAD + 40) * 2, 4,
            0.6, THREAD[1], THREAD[2], THREAD[3])
    else
        self:drawRect(PAD + 24, self.stitchY, w - (PAD + 24) * 2, 2, 0.7,
            THREAD[1], THREAD[2], THREAD[3])
    end

    -- ── page-marker tabs (active one flows into the page below) ──
    local tabs = { { "TRAITS", false }, { "BONDS", true }, { "NOTES", false } }
    local tabW = math.floor((w - PAD * 2 - 8 * 2) / 3)
    for i, t in ipairs(tabs) do
        local tx = PAD + (i - 1) * (tabW + 8)
        local base = t[2] and "tab_active" or "tab_inactive"
        if not three(self, base, tx, self.tabsY, tabW, self.tabH, 12) then
            local c = t[2] and { 0.85, 0.81, 0.71 } or { 0.56, 0.51, 0.41 }
            self:drawRect(tx, self.tabsY, tabW, self.tabH, 1, c[1], c[2], c[3])
        end
        local ink = t[2] and INK or INK_ON_DIM
        local lblY = self.tabsY + math.floor((self.tabH - H(UIFont.Small)) / 2) + (t[2] and 0 or 2)
        self:drawTextCentre(t[1], tx + tabW / 2, lblY, ink[1], ink[2], ink[3],
            t[2] and 1 or 0.6, UIFont.Small)
    end

    -- ── scroll rail skin along the page's right edge ──
    local track, thumb = tex("scroll_track"), tex("scroll_thumb")
    if track then
        local rx = self.page.x + self.page.width - 15
        local ry = self.page.y + 10
        local rh = self.page.height - 20
        self:drawTextureScaled(track, rx, ry, 11, rh, 0.9, 1, 1, 1)
        if thumb then
            self:drawTextureScaled(thumb, rx, ry + 4, 11, math.floor(rh * 0.42), 0.95, 1, 1, 1)
        end
    end

    -- ── stamped-label buttons ──
    local function button(label, bx, bw)
        if not nine(self, "btn", bx, self.buttonsY, bw, self.btnH, 12, true) then
            self:drawRect(bx, self.buttonsY, bw, self.btnH, 1, 0.83, 0.78, 0.66)
            self:drawRectBorder(bx, self.buttonsY, bw, self.btnH, 1, INK[1], INK[2], INK[3])
        end
        self:drawTextCentre(label, bx + bw / 2,
            self.buttonsY + math.floor((self.btnH - H(UIFont.Small)) / 2),
            INK[1], INK[2], INK[3], 1, UIFont.Small)
    end
    button("Study Equipped", w - PAD - 160, 160)
    button("Close", math.floor((w - 110) / 2), 110)

    -- ── embossed cover frame, over everything at the panel edge ──
    if not nine(self, "cover", 0, 0, w, self.height, 32, false) then
        self:drawRectBorder(0, 0, w, self.height, 1, 0.45, 0.36, 0.22)
    end
end

function VPSJournal.build()
    local root = Journal:new(30, 24)
    root:initialise()
    return root
end

return VPSJournal
