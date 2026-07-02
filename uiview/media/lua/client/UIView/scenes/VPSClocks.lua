--[[
    UIView - VPS kill-clock iteration sheet
    =======================================
    Three treatments of the 24-hour kill clock, side by side on paper:

      A. HOUR DOTS   - dots + ink-weight by night/day density, cardinal ticks
                       (data we track TODAY: nightKills/kills + firstKillHour)
      B. KILL ROSE   - radial histogram: stroke LENGTH = that hour's kills
                       (needs new 24-bucket hour tracking - one packed string)
      C. INKED ARC   - solid night band + rose spikes, heavier artifact feel

    All three: red ring/spike = hour of first blood. Midnight at top.
]]

require "UIView/UIMock"
local fm = UIView_fontMetrics

local VPSClocks = {}

local P = {
    PAPER = { 0.855, 0.815, 0.72, 1.0 },
    EDGE  = { 0.62, 0.56, 0.44, 1.0 },
    INK       = { 0.24, 0.20, 0.15, 1.0 },
    INK_FADE  = { 0.45, 0.40, 0.32, 1.0 },
    INK_LIGHT = { 0.55, 0.50, 0.42, 0.9 },
    RED   = { 0.55, 0.20, 0.16, 1.0 },
}

-- Mock 24-bucket kill histogram: a night hunter with a 22:00 spike and a
-- small noon bump (fights at home base). Index 1 = hour 0.
local HOURS = { 30, 26, 22, 14, 8, 2, 1, 0, 2, 3, 5, 9,
                14, 8, 4, 3, 2, 4, 7, 12, 18, 36, 48, 40 }
local FIRST_BLOOD = 22

local Sheet = ISPanel:derive("VPSClockSheet")

function Sheet:new(x, y)
    local o = ISPanel.new(self, x, y, 760, 320)
    o:setBackgroundColor(P.PAPER[1], P.PAPER[2], P.PAPER[3], P.PAPER[4])
    o:setBorderColor(P.EDGE[1], P.EDGE[2], P.EDGE[3], 1)
    return o
end

local function H(font) return fm(font).h end

--- shared bits ---------------------------------------------------------------

local function maxHour()
    local mx = 1
    for _, v in ipairs(HOURS) do if v > mx then mx = v end end
    return mx
end

local function hourAngle(h)
    return (h / 24) * 2 * math.pi - math.pi / 2
end

--- A: hour dots (today's data), cardinal ticks -------------------------------
local function drawDots(self, ccx, ccy, R, dot)
    local total, night = 0, 0
    for h = 0, 23 do
        total = total + HOURS[h + 1]
        if h >= 21 or h < 5 then night = night + HOURS[h + 1] end
    end
    local nightRatio = night / total
    local nPH, dPH = nightRatio / 8, (1 - nightRatio) / 16
    local norm = nPH + dPH
    for h = 0, 23 do
        local ang = hourAngle(h)
        local px, py = ccx + math.cos(ang) * R, ccy + math.sin(ang) * R
        local isNight = (h >= 21 or h < 5)
        local a = 0.15 + 0.8 * ((isNight and nPH or dPH) / norm)
        local dx, dy
        if h % 6 == 0 then
            local tl = dot * 2
            if h == 0 or h == 12 then
                dx, dy = math.floor(px - dot / 2), math.floor(py - tl / 2)
                self:drawRect(dx, dy, dot, tl, math.max(a, 0.45), P.INK[1], P.INK[2], P.INK[3])
            else
                dx, dy = math.floor(px - tl / 2), math.floor(py - dot / 2)
                self:drawRect(dx, dy, tl, dot, math.max(a, 0.45), P.INK[1], P.INK[2], P.INK[3])
            end
        else
            dx, dy = math.floor(px - dot / 2), math.floor(py - dot / 2)
            self:drawRect(dx, dy, dot, dot, a, P.INK[1], P.INK[2], P.INK[3])
        end
        if h == FIRST_BLOOD then
            self:drawRectBorder(dx - 3, dy - 3, dot + 6, dot + 6, 0.9, P.RED[1], P.RED[2], P.RED[3])
        end
    end
end

--- B: kill rose — stroke length = that hour's kills --------------------------
local function drawRose(self, ccx, ccy, R, dot)
    local mx = maxHour()
    for h = 0, 23 do
        local ang = hourAngle(h)
        local frac = HOURS[h + 1] / mx
        local len = math.max(2, math.floor(R * 0.75 * frac))
        -- stroke drawn as small squares stepping outward from an inner ring
        -- (rect-only radial line)
        local r0 = math.floor(R * 0.35)
        local steps = math.max(1, math.floor(len / math.max(2, dot - 1)))
        local isFirst = (h == FIRST_BLOOD)
        local c = isFirst and P.RED or P.INK
        for s = 0, steps do
            local rr = r0 + math.floor((len * s) / steps)
            local px = ccx + math.cos(ang) * rr
            local py = ccy + math.sin(ang) * rr
            self:drawRect(math.floor(px - dot / 2), math.floor(py - dot / 2), dot, dot,
                0.30 + 0.6 * frac, c[1], c[2], c[3])
        end
    end
    -- faint inner ring anchors the dial
    for h = 0, 23 do
        local ang = hourAngle(h)
        local px = ccx + math.cos(ang) * math.floor(R * 0.30)
        local py = ccy + math.sin(ang) * math.floor(R * 0.30)
        self:drawRect(math.floor(px - 1), math.floor(py - 1), 2, 2, 0.35, P.INK_LIGHT[1], P.INK_LIGHT[2], P.INK_LIGHT[3])
    end
end

--- C: inked night arc + rose spikes ------------------------------------------
local function drawArcRose(self, ccx, ccy, R, dot)
    -- night band: dense small squares along the 21:00-05:00 arc
    for i = 0, 64 do
        local h = 21 + (i / 64) * 8   -- 21..29 (=05)
        local ang = hourAngle(h % 24)
        local px = ccx + math.cos(ang) * R
        local py = ccy + math.sin(ang) * R
        self:drawRect(math.floor(px - dot / 2), math.floor(py - dot / 2), dot, dot,
            0.30, P.INK[1], P.INK[2], P.INK[3])
    end
    -- rose spikes on top
    local mx = maxHour()
    for h = 0, 23 do
        local ang = hourAngle(h)
        local frac = HOURS[h + 1] / mx
        if frac > 0.04 then
            local len = math.max(2, math.floor(R * 0.62 * frac))
            local r0 = R - 2
            local steps = math.max(1, math.floor(len / 2))
            local isFirst = (h == FIRST_BLOOD)
            local c = isFirst and P.RED or P.INK
            for s = 0, steps do
                local rr = r0 - math.floor((len * s) / steps)   -- spikes grow INWARD
                local px = ccx + math.cos(ang) * rr
                local py = ccy + math.sin(ang) * rr
                self:drawRect(math.floor(px - 1), math.floor(py - 1), 3, 3,
                    0.45 + 0.5 * frac, c[1], c[2], c[3])
            end
        end
    end
end

function Sheet:render()
    local sfh = H(UIFont.Small)
    local R = math.floor(sfh * 4.2)
    local dot = math.max(3, math.floor(sfh * 0.3))
    local cy = math.floor(self.height / 2) + sfh
    local labels = { "A  hour dots (data we have)", "B  kill rose (needs hour log)", "C  night arc + spikes" }
    local draws = { drawDots, drawRose, drawArcRose }
    for i = 1, 3 do
        local cx = math.floor(self.width * (i - 0.5) / 3)
        draws[i](self, cx, cy, R, dot)
        self:drawTextCentre(labels[i], cx, 14, P.INK_FADE[1], P.INK_FADE[2], P.INK_FADE[3], 1, UIFont.Small)
    end
end

function VPSClocks.build()
    local root = Sheet:new(20, 20)
    root:initialise()
    return root
end

return VPSClocks
