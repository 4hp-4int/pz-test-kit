--[[
    UIView — Scene: SIR "Lenses" POC
    ================================
    Design proof for the lens system: ONE inventory, three readings. The same
    item rows are rendered three times, each through a different lens that
    re-projects the item's REAL B42 state into a right-side "stat lane" of
    microcharts. Nothing here touches SIR mod code — it's a pixel mock so we can
    react to the idea before building it for real.

    Every lane metric maps to a verified B42 getter:
      COMBAT     getCondition/Max, getMaxDamage, getCurrentAmmoCount/getMaxAmmo,
                 getSharpness/getMaxSharpness, getCriticalChance, vs-equipped dmg
      SURVIVAL   getAge/getRottenTime (freshness drain), getHungerChange,
                 getCalories, getCurrentUsesFloat (drainable doses), isRotten
      LOGISTICS  getActualWeight / carry-capacity, container getContentsWeight/
                 getCapacity, stack count

    Mock values below are realistic stand-ins for those getters.
]]

require "UIView/UIMock"
UIView_setScreen(940, 600)

local Scene = {}
Scene.frame = { w = 940, h = 600 }

-- ---- palette ---------------------------------------------------------------
local BG      = { 0.055, 0.055, 0.075 }
local PANEL   = { 0.085, 0.085, 0.11 }
local ALT     = { 1, 1, 1, 0.035 }
local TXT     = { 0.88, 0.88, 0.90 }
local SUB     = { 0.55, 0.55, 0.60 }
local DIM     = { 0.32, 0.32, 0.36 }
local TRACK   = { 1, 1, 1, 0.12 }
local GOOD    = { 0.42, 0.85, 0.46 }
local WARN    = { 0.98, 0.74, 0.22 }
local BAD     = { 0.95, 0.36, 0.32 }
local LENSES  = {
    { id = "combat",    name = "COMBAT",    accent = { 0.96, 0.46, 0.36 }, legend = "condition - damage - ammo/edge - vs equipped" },
    { id = "survival",  name = "SURVIVAL",  accent = { 0.46, 0.86, 0.48 }, legend = "freshness - hunger - calories - doses" },
    { id = "logistics", name = "LOGISTICS", accent = { 0.46, 0.70, 0.96 }, legend = "weight share - pack fill - stack" },
}

-- ---- mock inventory (one list, shared across all three lenses) --------------
-- frac fields are pre-normalized 0..1 from the real getters they stand in for.
local ITEMS = {
    { name = "M9 Pistol",    icon = "Item_Revolver",   kind = "gun",   sub = "ranged - equipped",
      cond = 0.70, dmg = 0.52, ammo = 12, ammoMax = 15, crit = 0.35, delta = "up",   wt = 0.014 },
    { name = "Hunting Knife", icon = "Item_HuntingKnife", kind = "blade", sub = "small blade",
      cond = 0.90, dmg = 0.30, edge = 0.80, delta = "down", wt = 0.008 },
    { name = "Fire Axe",     icon = "Item_Axe",        kind = "blade", sub = "axe",
      cond = 0.40, dmg = 0.82, edge = 0.55, delta = "up",   wt = 0.10 },
    { name = "Apple",        icon = "Item_Apple",      kind = "food",  sub = "fresh",
      fresh = 0.82, fill = 0.30, cal = 0.10, wt = 0.006 },
    { name = "Steak",        icon = "Item_Steak",      kind = "food",  sub = "going off",
      fresh = 0.18, fill = 0.80, cal = 0.55, wt = 0.012 },
    { name = "Tinned Beans", icon = "Item_CannedPeas", kind = "food", sub = "packaged - no decay",
      fresh = nil,  fill = 0.62, cal = 0.45, wt = 0.030 },
    { name = "Painkillers",  icon = "Item_Pills",      kind = "drainable", sub = "medicine",
      doses = 6, dosesMax = 10, wt = 0.002 },
    { name = "Duffel Bag",   icon = "Item_Duffelbag",  kind = "container", sub = "8.4 / 20 cap",
      pack = 0.42, wt = 0.024 },
}

-- ---- micro-chart primitives ------------------------------------------------
local SMALL = UIFont.Small

local function lerpColor(frac)  -- red(0) -> amber(.5) -> green(1)
    if frac >= 0.5 then
        local t = (frac - 0.5) * 2
        return WARN[1] + (GOOD[1]-WARN[1])*t, WARN[2] + (GOOD[2]-WARN[2])*t, WARN[3] + (GOOD[3]-WARN[3])*t
    else
        local t = frac * 2
        return BAD[1] + (WARN[1]-BAD[1])*t, BAD[2] + (WARN[2]-BAD[2])*t, BAD[3] + (WARN[3]-BAD[3])*t
    end
end

-- a labeled horizontal bar: [LABEL] [====track/fill====] [value]
local function metric(self, x, y, label, frac, value, r, g, b)
    frac = math.max(0, math.min(1, frac or 0))
    self:drawText(label, x, y - 1, SUB[1], SUB[2], SUB[3], 1, SMALL)
    local bx, bw, bh = x + 34, 58, 7
    self:drawRect(bx, y + 1, bw, bh, TRACK[4], TRACK[1], TRACK[2], TRACK[3])
    self:drawRect(bx, y + 1, math.max(1, bw * frac), bh, 1, r, g, b)
    if value then self:drawText(value, bx + bw + 6, y - 1, TXT[1], TXT[2], TXT[3], 1, SMALL) end
end

-- discrete pips (e.g. doses remaining)
local function pips(self, x, y, n, total, r, g, b)
    self:drawText("DOSE", x, y - 1, SUB[1], SUB[2], SUB[3], 1, SMALL)
    local px, pw, gap = x + 34, 7, 2
    for i = 1, total do
        local on = i <= n
        local a = on and 1 or 0.18
        self:drawRect(px + (i-1)*(pw+gap), y + 1, pw, 7, a, r, g, b)
    end
    self:drawText(n .. "/" .. total, x + 34 + total*(pw+gap) + 4, y - 1, TXT[1], TXT[2], TXT[3], 1, SMALL)
end

local function deltaArrow(self, x, y, dir)
    local tex = getTexture(dir == "up" and "sir_arrow-up" or "sir_arrow-down")
    local c = dir == "up" and GOOD or BAD
    if tex then self:drawTextureScaledAspect(tex, x, y, 12, 12, 1, c[1], c[2], c[3]) end
end

local function dimDash(self, x, y)
    self:drawText("- not in this lens -", x, y, DIM[1], DIM[2], DIM[3], 1, SMALL)
end

-- ---- per-lens stat lane ----------------------------------------------------
local function drawLane(self, lens, it, lx, ly)
    if lens == "combat" then
        if it.kind == "gun" or it.kind == "blade" then
            local cr, cg, cb = lerpColor(it.cond)
            metric(self, lx, ly,      "COND", it.cond, nil, cr, cg, cb)
            metric(self, lx, ly + 13, "DMG",  it.dmg,  nil, 0.95, 0.55, 0.4)
            if it.kind == "gun" then
                metric(self, lx, ly + 26, "AMMO", it.ammo/it.ammoMax, it.ammo.."/"..it.ammoMax, 0.9, 0.8, 0.5)
            else
                metric(self, lx, ly + 26, "EDGE", it.edge, nil, 0.7, 0.85, 0.95)
            end
            if it.delta then deltaArrow(self, lx + 108, ly + 6, it.delta) end
        else
            dimDash(self, lx, ly + 10)
        end

    elseif lens == "survival" then
        if it.kind == "food" then
            if it.fresh ~= nil then
                local fr, fg, fb = lerpColor(it.fresh)
                local lbl = it.fresh < 0.25 and "SPOIL" or "FRESH"
                metric(self, lx, ly, lbl, it.fresh, nil, fr, fg, fb)
            else
                metric(self, lx, ly, "SHELF", 1.0, "stable", 0.5, 0.6, 0.82)
            end
            metric(self, lx, ly + 13, "FILL", it.fill, nil, 0.5, 0.8, 0.55)
            metric(self, lx, ly + 26, "KCAL", it.cal,  nil, 0.85, 0.8, 0.45)
        elseif it.kind == "drainable" then
            pips(self, lx, ly + 10, it.doses, it.dosesMax, 0.5, 0.8, 0.95)
        else
            dimDash(self, lx, ly + 10)
        end

    else -- logistics (every item participates)
        metric(self, lx, ly, "WT", math.min(1, it.wt / 0.12), string.format("%.1fkg", it.wt * 8), 0.5, 0.7, 0.95)
        if it.pack ~= nil then
            metric(self, lx, ly + 13, "PACK", it.pack, nil, 0.6, 0.6, 0.95)
        end
    end
end

-- ---- root panel ------------------------------------------------------------
function Scene.build()
    local W, H = Scene.frame.w, Scene.frame.h
    local root = ISPanel:new(0, 0, W, H)
    root:initialise()

    root.render = function(self)
        self:drawRect(0, 0, W, H, 1, BG[1], BG[2], BG[3])

        -- title strip
        self:drawText("SIR LENSES", 14, 12, TXT[1], TXT[2], TXT[3], 1, UIFont.Medium)
        self:drawText("one inventory, three readings - press a key to switch the lens",
            120, 15, SUB[1], SUB[2], SUB[3], 1, SMALL)

        local colW, gap, x0, top = 296, 14, 14, 50
        for ci, lens in ipairs(LENSES) do
            local cx = x0 + (ci - 1) * (colW + gap)

            -- column panel + header
            self:drawRect(cx, top, colW, H - top - 12, 1, PANEL[1], PANEL[2], PANEL[3])
            local ac = lens.accent
            self:drawRect(cx, top, colW, 30, 1, ac[1]*0.30, ac[2]*0.30, ac[3]*0.30)
            self:drawRect(cx, top, 4, 30, 1, ac[1], ac[2], ac[3])
            self:drawText(lens.name, cx + 12, top + 5, ac[1], ac[2], ac[3], 1, UIFont.Medium)
            self:drawText(lens.legend, cx + 12, top + 32, SUB[1], SUB[2], SUB[3], 1, SMALL)

            -- rows
            local rowH, ry = 50, top + 52
            for ri, it in ipairs(ITEMS) do
                local y = ry + (ri - 1) * rowH
                if ri % 2 == 0 then self:drawRect(cx, y, colW, rowH, ALT[4], ALT[1], ALT[2], ALT[3]) end

                -- item icon
                local tex = getTexture(it.icon)
                if tex then self:drawTextureScaledAspect(tex, cx + 8, y + 9, 30, 30, 1, 1, 1, 1) end
                -- name + sub
                self:drawText(it.name, cx + 44, y + 8, TXT[1], TXT[2], TXT[3], 1, SMALL)
                self:drawText(it.sub,  cx + 44, y + 25, SUB[1], SUB[2], SUB[3], 1, SMALL)
                -- divider
                self:drawRect(cx + 6, y + rowH - 1, colW - 12, 1, 0.06, 1, 1, 1)
                -- stat lane
                drawLane(self, lens.id, it, cx + 158, y + 8)
            end
        end
    end

    return root
end

return Scene
