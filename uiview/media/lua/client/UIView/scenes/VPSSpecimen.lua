--[[
    UIView - VPS "Specimen Page" concept, v3: SHOW, DON'T TELL
    ==========================================================
    A page from Morrison's Field Journal. v3 discipline: the localisation
    budget is ALREADY SPENT - the page is assembled from existing localized
    strings (affix names, condition phrases, trait/mood names, mood flavor)
    plus NUMERALS and INK DRAWINGS. No new prose keys beyond section labels.

    The drawings carry the story:
      - BODY GLYPHS under the title: one square per life, dead ones struck
        through in red. Three squares, two struck = third body. Zero words.
      - THE KILL CLOCK: 24 hour-dots in a ring; night hours inked heavier by
        the night-kill share; the first-blood hour wears a red ring.
      - growth ticks for classification; tally marks for mendings (4 / 13).
]]

require "UIView/UIMock"
local fm = UIView_fontMetrics

local VPSSpecimen = {}

-- ── ink & paper ──────────────────────────────────────────────────────────────
local P = {
    PAPER     = { 0.855, 0.815, 0.72, 1.0 },
    PAPER_EDGE= { 0.62, 0.56, 0.44, 1.0 },
    INK       = { 0.24, 0.20, 0.15, 1.0 },
    INK_FADE  = { 0.45, 0.40, 0.32, 1.0 },
    INK_LIGHT = { 0.55, 0.50, 0.42, 0.9 },
    RULE      = { 0.50, 0.44, 0.34, 0.55 },
    RED       = { 0.55, 0.20, 0.16, 1.0 },
    TEAL_INK  = { 0.16, 0.42, 0.38, 1.0 },
}

-- Only already-localized strings + numerals live here.
local MODEL = {
    number = "III",
    name = "Undying-Wrought Fire Axe of the Red Feast",
    generation = 3,
    classification = "Proven", stageIndex = 5, stageTotal = 9,
    kills = 812, nightRatio = 0.62, firstKillHour = 22,
    trait = "Patient", mood = "Gorged",
    moodColor = { 0.55, 0.20, 0.16 },
    moodFlavor = "It has drunk deep, and sits heavy in the hand.",
    behaviors = {
        { active = false, teal = true,  name = "Undying-Wrought", stats = "wear -75%  tree +60", cond = "near breaking" },
        { active = true,  teal = true,  name = "of the Red Feast", stats = "+14% crit",           cond = "in blood" },
        { active = true,  teal = false, name = "Keen",             stats = "+8% crit",            cond = nil },
    },
    mendsUsed = 4, mendBudget = 13,
    margin = "What the mendings take, they do not give back.",
    signoff = "- R.L.M.",
}

local Page = ISPanel:derive("VPSSpecimenPage")
local PAGE_W = 400

function Page:new(x, y, model)
    local o = ISPanel.new(self, x, y, PAGE_W, 100)
    o:setBackgroundColor(P.PAPER[1], P.PAPER[2], P.PAPER[3], P.PAPER[4])
    o:setBorderColor(P.PAPER_EDGE[1], P.PAPER_EDGE[2], P.PAPER_EDGE[3], 1)
    o.model = model
    o.height = o:measure()
    return o
end

local function H(font) return fm(font).h end

function Page:layout(draw)
    local m = self.model
    local pad = math.floor(H(UIFont.Small) * 1.3)
    local w = self.width
    local y = pad

    local function text(s, x, font, c, a)
        if draw then self:drawText(s, x, y, c[1], c[2], c[3], a or c[4] or 1, font) end
    end
    local function advance(font, mult) y = y + math.floor(H(font) * (mult or 1)) end
    local function gap(mult) y = y + math.floor(H(UIFont.Small) * (mult or 0.5)) end
    local function rule(inkC)
        local c = inkC or P.RULE
        if draw then self:drawRect(pad, y, w - pad * 2, 1, c[4] or 0.55, c[1], c[2], c[3]) end
        y = y + 1; gap(0.55)
    end
    local function measure(font, s) return math.floor(#tostring(s) * fm(font).w + 0.5) end
    local function wrapped(s, x, font, c, maxW, lineMult)
        local line = ""
        for word in tostring(s):gmatch("%S+") do
            local probe = (line == "") and word or (line .. " " .. word)
            if measure(font, probe) > maxW and line ~= "" then
                text(line, x, font, c); advance(font, lineMult or 1.05); line = word
            else line = probe end
        end
        if line ~= "" then text(line, x, font, c); advance(font, lineMult or 1.05) end
    end

    -- ── letterhead ──
    text("FIELD NOTES", pad, UIFont.Small, P.INK_FADE)
    if draw then
        self:drawTextRight("SPECIMEN No. " .. m.number, w - pad, y,
            P.INK_FADE[1], P.INK_FADE[2], P.INK_FADE[3], 1, UIFont.Small)
    end
    advance(UIFont.Small, 1.5)

    -- ── specimen name ──
    rule(P.INK)
    wrapped(m.name, pad, UIFont.Large, P.INK, w - pad * 2, 1.08)
    gap(0.2)
    -- bodies: one glyph per life, the dead struck through in red. no words.
    do
        local bg = math.max(7, math.floor(H(UIFont.Small) * 0.7))
        local bgap = math.floor(bg * 0.7)
        if draw then
            for i = 1, m.generation do
                local bx2 = pad + (i - 1) * (bg + bgap)
                local dead = i < m.generation
                local c = dead and P.INK_LIGHT or P.TEAL_INK
                self:drawRectBorder(bx2, y, bg, bg, dead and 0.7 or 1.0, c[1], c[2], c[3])
                if dead then
                    self:drawRect(bx2 - 1, y + math.floor(bg / 2) - 1, bg + 2, 2, 0.85, P.RED[1], P.RED[2], P.RED[3])
                else
                    local inset = math.max(2, math.floor(bg * 0.3))
                    self:drawRect(bx2 + inset, y + inset, bg - inset * 2, bg - inset * 2, 0.9, c[1], c[2], c[3])
                end
            end
        end
        y = y + bg
    end
    gap(0.5)
    rule(P.INK)
    gap(0.4)

    -- ── classification: stage word + growth ticks ──
    text("classification:", pad, UIFont.Small, P.INK_FADE)
    local cx = pad + measure(UIFont.Small, "classification:") + math.floor(H(UIFont.Small) * 0.5)
    text(m.classification, cx, UIFont.Medium, P.INK)
    local tickW = math.max(2, math.floor(H(UIFont.Small) * 0.14))
    local tickGap = math.floor(H(UIFont.Small) * 0.42)
    local tx = w - pad - (m.stageTotal * (tickW + tickGap) - tickGap)
    if draw then
        for i = 1, m.stageTotal do
            local reached = i <= m.stageIndex
            local th = reached and math.floor(H(UIFont.Medium) * 0.7) or math.floor(H(UIFont.Medium) * 0.4)
            local ty = y + H(UIFont.Medium) - th
            local c = reached and P.INK or P.INK_LIGHT
            self:drawRect(tx + (i - 1) * (tickW + tickGap), ty, tickW, th, c[4] or 1, c[1], c[2], c[3])
        end
    end
    advance(UIFont.Medium, 1.6)

    -- ── THE KILL CLOCK + the numbers ──
    do
        local R = math.floor(H(UIFont.Small) * 3.0)
        local dot = math.max(3, math.floor(H(UIFont.Small) * 0.3))
        local ccx = pad + R + dot * 2
        local ccy = y + R + dot
        if draw then
            -- Per-HOUR kill density: night is 8 hours, day is 16 — normalize so
            -- a true night-hunter's night dots ink darker than its day dots.
            -- Night hours are also drawn slightly LARGER: size + ink carry the
            -- same fact twice, which survives every display scale.
            local nPH = m.nightRatio / 8
            local dPH = (1 - m.nightRatio) / 16
            local total = nPH + dPH
            for h = 0, 23 do
                local ang = (h / 24) * 2 * math.pi - math.pi / 2
                local px = ccx + math.cos(ang) * R
                local py = ccy + math.sin(ang) * R
                local isNight = (h >= 21 or h < 5)
                local density = (isNight and nPH or dPH) / total
                local a = 0.15 + 0.8 * density
                local dsz = dot + (density > 0.5 and 1 or 0)
                local dx, dy
                if h % 6 == 0 then
                    -- cardinal hours read as clock-face ticks: radial strokes at
                    -- midnight/noon (vertical) and 06/18 (horizontal)
                    local tl = dot * 2
                    if h == 0 or h == 12 then
                        dx = math.floor(px - dsz / 2); dy = math.floor(py - tl / 2)
                        self:drawRect(dx, dy, dsz, tl, math.max(a, 0.45), P.INK[1], P.INK[2], P.INK[3])
                    else
                        dx = math.floor(px - tl / 2); dy = math.floor(py - dsz / 2)
                        self:drawRect(dx, dy, tl, dsz, math.max(a, 0.45), P.INK[1], P.INK[2], P.INK[3])
                    end
                else
                    dx = math.floor(px - dsz / 2); dy = math.floor(py - dsz / 2)
                    self:drawRect(dx, dy, dsz, dsz, a, P.INK[1], P.INK[2], P.INK[3])
                end
                if h == m.firstKillHour then
                    self:drawRectBorder(dx - 3, dy - 3, dsz + 6, dsz + 6, 0.9, P.RED[1], P.RED[2], P.RED[3])
                end
            end
            -- caption beneath the dial (locale-safe: the ring interior is too
            -- tight once cardinal ticks claim the horizontal axis)
            self:drawTextCentre("hours active", ccx, ccy + R + dot * 3,
                P.INK_FADE[1], P.INK_FADE[2], P.INK_FADE[3], 0.9, UIFont.Small)
        end
        -- beside the clock: big numerals + temper/mood in existing words
        local rxx = ccx + R + dot * 5
        local yy = y + math.floor(H(UIFont.Small) * 0.5)
        if draw then
            self:drawText(tostring(m.kills), rxx, yy, P.INK[1], P.INK[2], P.INK[3], 1, UIFont.Large)
            self:drawText("kills", rxx + measure(UIFont.Large, tostring(m.kills)) + math.floor(H(UIFont.Small) * 0.4),
                yy + H(UIFont.Large) - H(UIFont.Small) - 2, P.INK_FADE[1], P.INK_FADE[2], P.INK_FADE[3], 1, UIFont.Small)
            local ty2 = yy + math.floor(H(UIFont.Large) * 1.4)
            self:drawText(m.trait, rxx, ty2, P.INK[1], P.INK[2], P.INK[3], 1, UIFont.Medium)
            local my2 = ty2 + math.floor(H(UIFont.Medium) * 1.2)
            self:drawRect(rxx + 1, my2 + math.floor(H(UIFont.Medium) / 2) - 3, 6, 6, 1, m.moodColor[1], m.moodColor[2], m.moodColor[3])
            self:drawText(m.mood, rxx + 12, my2, m.moodColor[1], m.moodColor[2], m.moodColor[3], 1, UIFont.Medium)
        end
        y = ccy + R + dot * 3 + math.floor(H(UIFont.Small) * 1.5)
    end
    -- one mood flavor line: already localized, already paid for
    wrapped("\"" .. m.moodFlavor .. "\"", pad, UIFont.Small, P.INK_LIGHT, w - pad * 2, 1.1)
    gap(0.5)

    -- ── observed behaviors: checkbox + existing-key strings only ──
    text("OBSERVED", pad, UIFont.Small, P.INK_FADE)
    advance(UIFont.Small, 1.35)
    local cb = math.max(7, math.floor(H(UIFont.Small) * 0.62))
    for _, b in ipairs(m.behaviors) do
        local ink = b.teal and P.TEAL_INK or P.INK
        if draw then
            local cy = y + math.floor((H(UIFont.Small) - cb) / 2)
            local ct = getTexture((b.teal and "vps_checkbox_teal_" or "vps_checkbox_walnut_")
                .. (b.active and "filled" or "empty"))
            if ct then
                self:drawTextureScaled(ct, pad, cy, cb, cb, 1, 1, 1, 1)
            else
                self:drawRectBorder(pad, cy, cb, cb, 0.9, ink[1], ink[2], ink[3])
                if b.active then
                    local inset = math.max(1, math.floor(cb * 0.2))
                    self:drawRect(pad + inset, cy + inset, cb - inset * 2, cb - inset * 2, 0.85, ink[1], ink[2], ink[3])
                end
            end
        end
        local bx = pad + cb + math.floor(cb * 0.7)
        text(b.name, bx, UIFont.Small, ink)
        -- stats column; if it would collide with the right-aligned condition,
        -- the condition drops to its own right-aligned line below.
        local statX = pad + math.floor((w - pad * 2) * 0.42)
        local condW = b.cond and measure(UIFont.Small, b.cond) or 0
        local fits = (statX + measure(UIFont.Small, b.stats) + math.floor(H(UIFont.Small) * 2.2) + condW) <= (w - pad)
        if draw then
            self:drawText(b.stats, statX, y, P.INK_FADE[1], P.INK_FADE[2], P.INK_FADE[3], 1, UIFont.Small)
            if b.cond and fits then
                local cc = b.active and P.RED or P.INK_LIGHT
                self:drawTextRight(b.cond, w - pad, y, cc[1], cc[2], cc[3], 1, UIFont.Small)
            end
        end
        advance(UIFont.Small, 1.35)
        if b.cond and not fits then
            if draw then
                local cc = b.active and P.RED or P.INK_LIGHT
                self:drawTextRight(b.cond, w - pad, y, cc[1], cc[2], cc[3], 1, UIFont.Small)
            end
            advance(UIFont.Small, 1.25)
        end
    end
    gap(0.35)

    -- ── mendings: tallies + numerals ──
    text("MENDINGS", pad, UIFont.Small, P.INK_FADE)
    advance(UIFont.Small, 1.35)
    do
        local th = math.floor(H(UIFont.Medium) * 0.85)
        local tw = math.max(2, math.floor(H(UIFont.Small) * 0.14))
        local tgap = math.floor(H(UIFont.Small) * 0.34)
        local groupGap = math.floor(H(UIFont.Small) * 0.7)
        local x = pad
        if draw then
            for i = 1, m.mendBudget do
                local used = i <= m.mendsUsed
                local c = used and P.RED or P.INK_LIGHT
                local a = used and 0.95 or 0.5
                if i % 5 == 0 and used then
                    local barY = y + math.floor(th * 0.45)
                    local barX = x - 4 * (tw + tgap)
                    self:drawRect(barX - 2, barY, 4 * (tw + tgap) + 2, math.max(2, math.floor(tw * 0.9)), a, c[1], c[2], c[3])
                    x = x + groupGap
                else
                    self:drawRect(x, y, tw, th, a, c[1], c[2], c[3])
                    x = x + tw + tgap + ((i % 5 == 0) and groupGap or 0)
                end
            end
            self:drawTextRight(m.mendsUsed .. " / " .. m.mendBudget, w - pad, y + math.floor((th - H(UIFont.Small)) / 2),
                P.INK_FADE[1], P.INK_FADE[2], P.INK_FADE[3], 1, UIFont.Small)
        end
        y = y + th
    end
    gap(0.6)

    -- ── marginalia + signoff ──
    rule()
    wrapped("\"" .. m.margin .. "\"", pad, UIFont.Small, P.RED, w - pad * 2, 1.1)
    if draw then
        self:drawTextRight(m.signoff, w - pad, y, P.INK[1], P.INK[2], P.INK[3], 0.9, UIFont.Small)
    end
    advance(UIFont.Small, 1.2)

    return y + pad
end

function Page:measure() return self:layout(false) end

-- Textured render: same chrome the mod draws, resolved from VPSChrome.pack
-- by build_view via the VorpallySauced asset root. Falls back to the flat
-- paper panel when a texture is missing.
function Page:render()
    local paper = getTexture("vps_paper_tile")
    if paper then
        local tile = 256
        for ix = 0, math.ceil(self.width / tile) - 1 do
            for iy = 0, math.ceil(self.height / tile) - 1 do
                self:drawTextureScaled(paper, ix * tile, iy * tile, tile, tile, 1, 1, 1, 1)
            end
        end
    end
    self:layout(true)
    if getTexture("vps_frame_tl") then
        local c = 24
        local w, h = self.width, self.height
        local function piece(n, x, y2, pw, ph)
            self:drawTextureScaled(getTexture(n), x, y2, pw, ph, 1, 1, 1, 1)
        end
        piece("vps_frame_tl", 0, 0, c, c);          piece("vps_frame_tr", w - c, 0, c, c)
        piece("vps_frame_bl", 0, h - c, c, c);      piece("vps_frame_br", w - c, h - c, c, c)
        piece("vps_frame_t", c, 0, w - c * 2, c);   piece("vps_frame_b", c, h - c, w - c * 2, c)
        piece("vps_frame_l", 0, c, c, h - c * 2);   piece("vps_frame_r", w - c, c, c, h - c * 2)
    end
end

function VPSSpecimen.build()
    local root = Page:new(40, 30, MODEL)
    root:initialise()
    return root
end

return VPSSpecimen
