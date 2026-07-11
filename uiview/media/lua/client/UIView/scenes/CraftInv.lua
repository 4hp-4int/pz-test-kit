--[[
    UIView — Scene: the craft window wearing SIR's craftdress
    ==========================================================
    A FAITHFUL mirror of ISHandcraftWindow's tree: window shell + header
    band, filter strip, category column, recipe list (icons, skill lines,
    favourite star, group header, uncraftable grey rows, per-row borders —
    doDrawNode's paint, line for line), recipe detail (title header,
    ingredient tiles with satisfaction borders, craft control + progress
    bar). Every draw goes through self:draw* so the REAL CraftDress wrap
    (shell, bare-walk, selection re-seat, ink translator) applies exactly
    as in-game.
]]

require "UIView/UIWidgets"
UIView_setScreen(1280, 800)

require "sir_chrome"
require "sir_craftdress"

local CraftInv = {}

local function tex(n) local t; pcall(function() t = getTexture(n) end); return t end

-- ── recipe list: doDrawNode/doDrawGroup mirrored ─────────────────────────
local function mkRecipeList(x, y, w, h)
    local p = ISPanel:new(x, y, w, h)
    p.background = false
    p:initialise()
    p.itemheight = 44
    p.selected = 3
    -- REAL base-class fields (the dress re-seats these)
    p.selectedColor = { r = 0.7, g = 0.35, b = 0.15, a = 0.3 }
    p.mouseOverColor = { r = 0.9, g = 0.9, b = 0.9, a = 0.1 }
    p.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    p.doDrawItem = function() end   -- marks this as a list for the dress
    p.rows = {
        { group = "Furniture" },
        { name = "Wooden Crate",   icon = "Item_Plank",  craftable = true,
          desc = "A sturdy storage crate.", skill = "Carpentry 2/2", good = true, fav = true },
        { name = "Sturdy Chair",   icon = "Item_Plank",  craftable = true,
          desc = "Somewhere to sit.",       skill = "Carpentry 3/3", good = true },
        { name = "Small Table",    icon = "Item_Plank",  craftable = false,
          desc = "A simple side table.",    skill = "Carpentry 4/2", good = false },
        { group = "Defenses" },
        { name = "Plank and Nails Wall", icon = "Item_Nails", craftable = false,
          desc = "Keeps them out. Mostly.", skill = "Carpentry 5/2", good = false },
    }
    p.render = function(self)
        local yy = 0
        local star = tex("media/ui/FavoriteStar.png") or tex("Item_Star")
        for i, row in ipairs(self.rows) do
            local rh = row.group and 24 or self.itemheight
            if i == self.selected then
                local sc = self.selectedColor
                self:drawRect(0, yy, self.width, rh - 1, sc.a, sc.r, sc.g, sc.b)
            end
            -- vanilla: per-row border, alpha hardcoded 0.5, rgb from field
            self:drawRectBorder(0, yy, self.width, rh, 0.5,
                self.borderColor.r, self.borderColor.g, self.borderColor.b)
            if row.group then
                self:drawText("> " .. row.group, 8, yy + 4, 1, 1, 1, 1, UIFont.Small)
            else
                local c = row.craftable and 1.0 or 0.5
                local ic = tex(row.icon)
                if ic then self:drawTextureScaledAspect(ic, 6, yy + 6, 32, 32, c, c, c, 1) end
                self:drawText(row.name, 46, yy + 4, c, c, c, 1, UIFont.Small)
                self:drawText(row.desc, 46, yy + 18, 0.5, 0.5, 0.5, 1, UIFont.NewSmall)
                if row.good then
                    self:drawText(row.skill, 46, yy + 30, 0, 0.8, 0, 1, UIFont.NewSmall)
                else
                    self:drawText(row.skill, 46, yy + 30, 0.8, 0, 0, 1, UIFont.NewSmall)
                end
                if row.fav and star then
                    self:drawTextureScaledAspect(star, self.width - 22, yy + 4, 16, 16, 1, 0, 0.8, 0)
                end
            end
            yy = yy + rh
        end
    end
    return p
end

-- ── category column (plain listbox rows, base-field selection) ──────────
local function mkCategories(x, y, w, h)
    local p = ISPanel:new(x, y, w, h)
    p.background = false
    p:initialise()
    p.selected = 2
    p.selectedColor = { r = 0.7, g = 0.35, b = 0.15, a = 0.3 }
    p.mouseOverColor = { r = 0.9, g = 0.9, b = 0.9, a = 0.1 }
    p.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    p.doDrawItem = function() end
    p.cats = { "All", "Carpentry", "Cooking", "Survival" }
    p.render = function(self)
        for i, c in ipairs(self.cats) do
            local yy = (i - 1) * 24
            if i == self.selected then
                local sc = self.selectedColor
                self:drawRect(0, yy, self.width, 23, sc.a, sc.r, sc.g, sc.b)
            end
            self:drawText(c, 8, yy + 4, 0.9, 0.9, 0.9, 1, UIFont.Small)
        end
    end
    return p
end

-- ── filter strip (entry box plate + combo, XUI-plate shaped) ────────────
local function mkFilter(x, y, w)
    local p = ISPanel:new(x, y, w, 28)
    p.background = false
    p:initialise()
    local entry = ISTextEntryBox:new("Filter recipes...", 4, 3, math.floor(w * 0.5), 22)
    entry:initialise()
    p:addChild(entry)
    local combo = ISComboBox:new(math.floor(w * 0.5) + 10, 3, 140, 22)
    combo:initialise()
    combo:addOption("Sort: Name")
    p:addChild(combo)
    return p
end

-- ── recipe detail: title header + ingredient tiles + craft control ──────
local function mkDetail(x, y, w, h)
    local p = ISPanel:new(x, y, w, h)
    p.background = false
    p:initialise()
    p.render = function(self)
        -- title header (ISWidgetTitleHeader shape)
        local ic = tex("Item_Plank")
        if ic then self:drawTextureScaledAspect(ic, 6, 4, 28, 28, 1, 1, 1, 1) end
        self:drawText("Wooden Crate", 42, 8, 1, 1, 1, 1, UIFont.Small)
        self:drawText("Inputs", 6, 44, 1, 1, 1, 1, UIFont.Medium)
        -- ingredient tiles: icon cell + SATISFACTION border (data ink —
        -- green ok / red missing, per-frame in vanilla)
        local tiles = {
            { icon = "Item_Plank", n = "4/4", ok = true },
            { icon = "Item_Nails", n = "0/8", ok = false },
        }
        for i, t in ipairs(tiles) do
            local tx = 6 + (i - 1) * 72
            -- in-game the tile fill rides the (bared) backgroundColor field
            local ba = (self.backgroundColor and self.backgroundColor.a or 1)
            self:drawRect(tx, 66, 64, 48, 0.6 * ba, 0.05, 0.05, 0.05)
            if t.ok then
                self:drawRectBorder(tx, 66, 64, 48, 1, 0.2, 0.7, 0.2)
            else
                self:drawRectBorder(tx, 66, 64, 48, 1, 0.8, 0.15, 0.1)
            end
            local it = tex(t.icon)
            if it then self:drawTextureScaledAspect(it, tx + 16, 70, 32, 32, 1, 1, 1, 1) end
            self:drawText(t.n, tx + 22, 100, 0.9, 0.9, 0.9, 1, UIFont.NewSmall)
        end
    end
    -- craft control strip (ISWidgetHandCraftControl shape: OWN bg field
    -- paint + progress bar + buttons)
    local ctrl = ISPanel:new(0, h - 64, w, 64)
    ctrl:setBackgroundColor(0.2, 0.2, 0.2, 0.5)
    ctrl.background = true
    ctrl:initialise()
    ctrl.render = function(self)
        self:drawRect(8, 8, self.width - 16, 12, 1, 0.1, 0.1, 0.1)
        self:drawRect(8, 8, math.floor((self.width - 16) * 0.6), 12, 1, 0.2, 0.7, 0.2)
    end
    local btn = ISButton:new(w - 108, 30, 100, 26, "Craft", ctrl, function() end)
    btn:initialise()
    ctrl:addChild(btn)
    p:addChild(ctrl)
    return p
end

function CraftInv.build()
    local SIR = _G.SauceInvRender
    SIR.Guard = SIR.Guard or { tripped = {}, trip = function() end }

    local win = ISCollapsableWindow:new(10, 10, 720, 430)
    win:setTitle("Craft")
    win:initialise()
    function win:titleBarHeight() return 16 end
    win.backgroundColor = win.backgroundColor or { a = 0.8 }
    win.borderColor = win.borderColor or { a = 1 }

    win:addChild(mkFilter(8, 22, 704))
    local cats = mkCategories(8, 56, 130, 360)
    win:addChild(cats)
    local recipes = mkRecipeList(146, 56, 300, 360)
    win:addChild(recipes)
    local detail = mkDetail(454, 56, 258, 360)
    win:addChild(detail)

    local origPrerender = win.prerender
    win.prerender = function(self)
        local ok, err = pcall(function() SIR.CraftDress.dressPre(self) end)
        if not ok then SIR.Guard.trip("craftdress", err) end
        origPrerender(self)
    end

    win._scene = { cats = cats, recipes = recipes, detail = detail }
    return win
end

return CraftInv
