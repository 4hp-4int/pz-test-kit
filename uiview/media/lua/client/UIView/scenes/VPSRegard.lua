--[[
    UIView - VPS "Regard" panel design scene
    ========================================
    The dedicated weapon-soul surface for VorpallySauced Hardcore: everything
    the tooltip was straining to carry (stage, power, temper, mood, marks with
    mutation state, lineage, mortality) gets room to breathe.

    Design language: start PLAIN. Dark field, hairline dividers, dim small-cap
    section labels, generous font-derived spacing. Stir-teal is the ONLY accent
    that means "mutation"; stage color carries identity; mortality runs a bar
    that DRAINS. Texture pass comes later - this is the legibility skeleton.

    All layout is font-height-driven (ports to the mod respecting the player's
    Font Size option - never fixed pixel constants for vertical rhythm).
]]

require "UIView/UIMock"
local fm = UIView_fontMetrics

local VPSRegard = {}

-- ── palette ─────────────────────────────────────────────────────────────────
local C = {
    BG        = { 0.050, 0.045, 0.065, 0.96 },
    BORDER    = { 0.36, 0.32, 0.27, 1.00 },
    TITLE     = { 0.92, 0.88, 0.82, 1.00 },
    SECTION   = { 0.48, 0.45, 0.41, 1.00 },  -- dim caps
    TEXT      = { 0.82, 0.80, 0.76, 1.00 },
    DIM       = { 0.58, 0.56, 0.52, 1.00 },
    LORE      = { 0.62, 0.50, 0.50, 1.00 },  -- muted red whisper
    DIVIDER   = { 0.30, 0.27, 0.24, 0.70 },
    STAGE     = { 0.85, 0.66, 0.38, 1.00 },  -- Proven (warm bronze)
    TEAL      = { 0.45, 0.85, 0.75, 1.00 },  -- species / lineage
    TEAL_HI   = { 0.25, 0.95, 0.85, 1.00 },  -- apex / awake
    TEAL_DIM  = { 0.40, 0.55, 0.52, 0.75 },  -- dormant
    GREEN     = { 0.60, 0.80, 0.60, 1.00 },  -- stat values
    BLOOD     = { 0.80, 0.55, 0.55, 1.00 },  -- blooded accents
    BAR_BG    = { 0.14, 0.13, 0.16, 1.00 },
    MORTAL    = { 0.62, 0.42, 0.38, 1.00 },  -- the body's remaining mendings
}

-- ── mock model: a rich 3rd-generation weapon showing every block ────────────
local MODEL = {
    name = "Undying-Wrought Fire Axe of the Red Feast",
    stageName = "Proven", stageIndex = 5, stageTotal = 9, power = 0.55,
    kills = 812, nextName = "Seasoned", nextKills = 600 + 812, -- flavor only
    generation = 3, ancestor = "Fire Axe",
    trait = "Patient", traitEffect = "+5% critical chance",
    mood = "Gorged", moodFlavor = "It has drunk deep, and sits heavy in the hand.",
    moodColor = { 0.85, 0.35, 0.30, 1.0 },
    marks = {
        { kind = "apex", name = "Undying-Wrought",
          stats = { "wear -75%", "tree damage +60" },
          trigger = "low_condition", triggerLabel = "WORN",
          state = "asleep", stateLine = "Asleep - it wakes near breaking." },
        { kind = "species", name = "of the Red Feast",
          stats = { "+14% critical chance" },
          trigger = "while_bloodied", triggerLabel = "BLOOD",
          state = "awake", stateLine = "Awake - it burns while drenched in blood." },
        { kind = nil, name = "Keen",
          stats = { "+8% critical chance" } },  -- unmutated: no chip, no state
    },
    mendsUsed = 4, mendBudget = 13,
    whisper = "The soul takes hold. It remembers.",
}

-- ── panel ────────────────────────────────────────────────────────────────────
local Regard = ISPanel:derive("VPSRegard")

local PANEL_W = 380

function Regard:new(x, y, model)
    -- height is measured from content in a dry-run pass
    local o = ISPanel.new(self, x, y, PANEL_W, 100)
    o:setBackgroundColor(C.BG[1], C.BG[2], C.BG[3], C.BG[4])
    o:setBorderColor(C.BORDER[1], C.BORDER[2], C.BORDER[3], C.BORDER[4])
    o.model = model
    o.height = o:measure()
    return o
end

-- Font-derived vertical rhythm.
local function H(font) return fm(font).h end

--- One layout function drives BOTH measuring and drawing: pass draw=false
--- to get the final height. (This is the portability trick - the mod version
--- keeps the same shape and swaps fm() for getTextManager():getFontHeight.)
function Regard:layout(draw)
    local m = self.model
    local pad = math.floor(H(UIFont.Small) * 0.9)
    local w = self.width
    local y = pad

    local function text(s, x, font, c)
        if draw then self:drawText(s, x, y, c[1], c[2], c[3], c[4] or 1, font) end
    end
    local function advance(font, mult) y = y + math.floor(H(font) * (mult or 1)) end
    local function gap(mult) y = y + math.floor(H(UIFont.Small) * (mult or 0.5)) end
    local function divider()
        if draw then self:drawRect(pad, y, w - pad * 2, 1, C.DIVIDER[4], C.DIVIDER[1], C.DIVIDER[2], C.DIVIDER[3]) end
        y = y + 1; gap(0.6)
    end
    local function section(label)
        text(string.upper(label), pad, UIFont.Small, C.SECTION)
        advance(UIFont.Small, 1.25)
    end
    -- word-wrap: emit as many lines as needed inside maxW.
    -- (mod port swaps measure for getTextManager():MeasureStringX)
    local function measure(font, s) return math.floor(#tostring(s) * fm(font).w + 0.5) end
    local function wrapped(s, x, font, c, maxW, lineMult)
        local line = ""
        for word in tostring(s):gmatch("%S+") do
            local probe = (line == "") and word or (line .. " " .. word)
            if measure(font, probe) > maxW and line ~= "" then
                text(line, x, font, c)
                advance(font, lineMult or 1.05)
                line = word
            else
                line = probe
            end
        end
        if line ~= "" then
            text(line, x, font, c)
            advance(font, lineMult or 1.05)
        end
    end

    -- ── header: name + lineage ──
    wrapped(m.name, pad, UIFont.Large, C.STAGE, w - pad * 2, 1.08)
    gap(0.15)
    if m.generation and m.generation > 0 then
        text("Third body - it was " .. m.ancestor .. ", once.", pad, UIFont.Small, C.TEAL)
        advance(UIFont.Small, 1.2)
    end
    gap(0.4); divider()

    -- ── THE STIR: stage rungs + power ──
    section("The Stir")
    text(m.stageName, pad, UIFont.Medium, C.STAGE)
    -- rung squares, right-aligned block
    local sq = math.max(4, math.floor(H(UIFont.Small) * 0.45))
    local sgap = math.max(2, math.floor(sq * 0.5))
    local rungsW = m.stageTotal * sq + (m.stageTotal - 1) * sgap
    local rx = w - pad - rungsW
    if draw then
        local ry = y + math.floor((H(UIFont.Medium) - sq) / 2)
        for i = 1, m.stageTotal do
            local lit = i <= m.stageIndex
            local cc = lit and C.STAGE or C.BAR_BG
            self:drawRect(rx + (i - 1) * (sq + sgap), ry, sq, sq, cc[4], cc[1], cc[2], cc[3])
        end
    end
    advance(UIFont.Medium, 1.25)
    -- power bar
    local barH = math.max(6, math.floor(H(UIFont.Small) * 0.55))
    if draw then
        local bw = w - pad * 2
        self:drawRect(pad, y, bw, barH, C.BAR_BG[4], C.BAR_BG[1], C.BAR_BG[2], C.BAR_BG[3])
        self:drawRect(pad, y, math.floor(bw * m.power), barH, 0.9, C.STAGE[1], C.STAGE[2], C.STAGE[3])
    end
    y = y + barH; gap(0.35)
    text(m.kills .. " kills", pad, UIFont.Small, C.DIM)
    if draw and m.nextName then
        self:drawTextRight(m.nextName .. " at " .. m.nextKills, w - pad, y,
            C.DIM[1], C.DIM[2], C.DIM[3], 1, UIFont.Small)
    end
    advance(UIFont.Small, 1.3)
    gap(0.3); divider()

    -- ── TEMPER: trait + mood ──
    section("Temper")
    text(m.trait, pad, UIFont.Medium, C.TEXT)
    if draw then
        self:drawTextRight(m.traitEffect, w - pad, y + math.floor((H(UIFont.Medium) - H(UIFont.Small)) / 2),
            C.GREEN[1], C.GREEN[2], C.GREEN[3], 1, UIFont.Small)
    end
    advance(UIFont.Medium, 1.15)
    text(m.mood, pad, UIFont.Medium, m.moodColor)
    advance(UIFont.Medium, 1.05)
    text("\"" .. m.moodFlavor .. "\"", pad, UIFont.Small, C.LORE)
    advance(UIFont.Small, 1.3)
    gap(0.3); divider()

    -- ── MARKS: affixes with requirement chips + state checkboxes ──
    -- Requirement chip: pictogram + caps label naming what the mark needs
    -- (WORN / BLOOD / NIGHT / DAWN / HORDE). Filled = condition met right now,
    -- hollow = dormant. Unconditional marks carry no chip. Pictograms are
    -- rect compositions so the plain pass needs no textures.
    section("Marks")

    -- requirement chip, right-aligned on the name row; returns nothing.
    -- Requirement chips: TEXT-ONLY (at chip size the word IS the icon), each
    -- requirement in its own tint so chips scan by color. Fill = met right now.
    local CHIP_TINT = {
        while_bloodied = { 0.85, 0.35, 0.32 },  -- blood red
        at_night       = { 0.55, 0.55, 0.90 },  -- night indigo
        at_dawn        = { 0.90, 0.70, 0.35 },  -- dawn amber
        low_condition  = { 0.80, 0.55, 0.40 },  -- worn rust
        horde          = { 0.70, 0.70, 0.68 },  -- horde gray
    }
    local function chip(rowY, trigger, label, awake)
        local sfh = H(UIFont.Small)
        local padIn = math.max(3, math.floor(sfh * 0.35))
        local labW = measure(UIFont.Small, label)
        local cw = padIn * 2 + labW
        local ch = sfh + padIn
        local cx = w - pad - cw
        local cy = rowY + math.floor((H(UIFont.Medium) - ch) / 2)
        local col = CHIP_TINT[trigger] or C.TEAL
        if draw then
            if awake then
                self:drawRect(cx, cy, cw, ch, 0.30, col[1], col[2], col[3])
                self:drawRectBorder(cx, cy, cw, ch, 1.0, col[1], col[2], col[3])
                self:drawText(label, cx + padIn, cy + math.floor((ch - sfh) / 2),
                    math.min(1, col[1] + 0.15), math.min(1, col[2] + 0.15), math.min(1, col[3] + 0.15), 1, UIFont.Small)
            else
                self:drawRectBorder(cx, cy, cw, ch, 0.45, col[1], col[2], col[3])
                self:drawText(label, cx + padIn, cy + math.floor((ch - sfh) / 2),
                    col[1], col[2], col[3], 0.55, UIFont.Small)
            end
        end
    end

    for _, mark in ipairs(m.marks) do
        local nameCol = (mark.kind == "apex") and C.TEAL_HI
            or (mark.kind == "species") and C.TEAL or C.TEXT
        local g = math.max(4, math.floor(H(UIFont.Small) * 0.4))
        local indent = pad + g + math.floor(g * 0.8)
        -- mutation identity glyph (kind marker): filled teal square; none for
        -- unmutated marks
        if draw and mark.kind then
            local gy = y + math.floor((H(UIFont.Medium) - g) / 2)
            self:drawRect(pad, gy, g, g, 0.95, nameCol[1], nameCol[2], nameCol[3])
        end
        -- name + requirement chip on the same row (one shared text column —
        -- unmutated marks simply have an empty glyph cell)
        text(mark.name, indent, UIFont.Medium, nameCol)
        if mark.trigger then
            chip(y, mark.trigger, mark.triggerLabel or "?", mark.state == "awake")
        end
        advance(UIFont.Medium, 1.1)
        for _, s in ipairs(mark.stats) do
            text(s, indent, UIFont.Small, C.GREEN)
            advance(UIFont.Small, 1.05)
        end
        -- state line with micro-checkbox: [x] awake / [ ] asleep
        if mark.stateLine then
            local sc = (mark.state == "awake") and C.TEAL_HI or C.TEAL_DIM
            local cb = math.max(6, math.floor(H(UIFont.Small) * 0.55))
            if draw then
                local cy2 = y + math.floor((H(UIFont.Small) - cb) / 2)
                self:drawRectBorder(indent, cy2, cb, cb, 0.8, sc[1], sc[2], sc[3])
                if mark.state == "awake" then
                    local inset = math.max(2, math.floor(cb * 0.25))
                    self:drawRect(indent + inset, cy2 + inset, cb - inset * 2, cb - inset * 2, 0.95, sc[1], sc[2], sc[3])
                end
            end
            text(mark.stateLine, indent + cb + math.floor(cb * 0.6), UIFont.Small, sc)
            advance(UIFont.Small, 1.15)
        end
        gap(0.35)
    end
    divider()

    -- ── THE BODY: mortality countdown ──
    section("The Body")
    text("Mended " .. m.mendsUsed .. " of " .. m.mendBudget .. " times.", pad, UIFont.Small, C.TEXT)
    advance(UIFont.Small, 1.2)
    if draw then
        local bw = w - pad * 2
        local remain = 1 - (m.mendsUsed / m.mendBudget)
        self:drawRect(pad, y, bw, barH, C.BAR_BG[4], C.BAR_BG[1], C.BAR_BG[2], C.BAR_BG[3])
        self:drawRect(pad, y, math.floor(bw * remain), barH, 0.85, C.MORTAL[1], C.MORTAL[2], C.MORTAL[3])
    end
    y = y + barH; gap(0.35)
    text("What the mendings take, they do not give back.", pad, UIFont.Small, C.DIM)
    advance(UIFont.Small, 1.3)
    gap(0.2); divider()

    -- ── footer whisper ──
    text("\"" .. m.whisper .. "\"", pad, UIFont.Small, C.LORE)
    advance(UIFont.Small, 1.1)

    return y + pad
end

function Regard:measure()
    return self:layout(false)
end

function Regard:render()
    self:layout(true)
end

function VPSRegard.build()
    local root = Regard:new(40, 30, MODEL)
    root:initialise()
    return root
end

return VPSRegard
