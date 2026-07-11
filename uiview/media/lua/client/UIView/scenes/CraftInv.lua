--[[
    UIView — Scene: the craft window wearing SIR's craftdress
    ==========================================================
    Mirrored from the ANATOMY SPEC of the real B42 hand-craft window
    (agent recon over the vanilla sources), at FONT_SCALE = 1:
      LIST_ICON_SIZE 32, LIST_SUBICON_SIZE 16, LIST_FAVICON_SIZE 10,
      title ICON_SIZE 48, property icons 16, BUTTON_HGT = fontHgt + 6,
      UI_BORDER_SPACING = 10 (list/categories) and 5 (filter/inputs/ctrl).
    Composition: title bar > header band (icon 32 + Medium title + info
    button) > ISHandCraftPanel columns [categories 125 | recipes(fill):
    filter strip + list | detail 350: title header / Required tiles /
    control strip]. Field-driven wherever the dress re-seats fields.
]]

require "UIView/UIWidgets"
UIView_setScreen(1280, 800)

require "sir_chrome"
require "sir_craftdress"

local CraftInv = {}

local FH = 19                 -- FONT_HGT_SMALL at scale 1 (spec: /19)
local BTN = FH + 6            -- BUTTON_HGT
local function tex(n) local t; pcall(function() t = getTexture(n) end); return t end

-- ── header band (ISHandcraftWindowHeader): icon 32 + Medium title ────────
local function mkHeader(w)
    local p = ISPanel:new(0, 16, w, 46)
    p.background = false
    p:initialise()
    p.render = function(self)
        local ic = tex("media/ui/craftingMenus/BuildProperty_Surface.png")
        if ic then self:drawTextureScaledAspect(ic, 22, 7, 32, 32, 1, 1, 1, 1) end
        self:drawText("Crafting", 22 + 32 + 15, 13, 1, 1, 0.95, 1, UIFont.Medium)
    end
    local info = ISButton:new(w - 24 - 14, 11, 24, 24, "i", p, function() end)
    info:initialise()
    p:addChild(info)
    return p
end

-- ── categories column (stock listbox rows, itemheight = FH + 10) ────────
local function mkCategories(x, y, h)
    local p = ISPanel:new(x, y, 125, h)
    p.background = false
    p:initialise()
    p.itemheight = FH + 10
    p.selected = 1
    p.selectedColor = { r = 0.7, g = 0.35, b = 0.15, a = 0.3 }
    p.mouseOverColor = { r = 0.9, g = 0.9, b = 0.9, a = 0.1 }
    p.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    p.doDrawItem = function() end
    p.cats = { "-- ALL --", "Favourites", "Carpentry", "Cooking", "Electrical", "Survival" }
    p.render = function(self)
        for i, c in ipairs(self.cats) do
            local yy = (i - 1) * self.itemheight
            if i == self.selected then
                local sc = self.selectedColor
                self:drawRect(0, yy, self.width, self.itemheight - 1, sc.a, sc.r, sc.g, sc.b)
            end
            self:drawText(c, 8, yy + 5, 0.9, 0.9, 0.9, 1, UIFont.Small)
        end
    end
    return p
end

-- ── filter strip (2 rows: search+combo+viewbtn / sort+tickbox) ──────────
local function mkFilter(x, y, w)
    local p = ISPanel:new(x, y, w, 6 + BTN + 5 + BTN + 6)
    p.background = false
    p:initialise()
    local entry = ISTextEntryBox:new("Search recipes...", 6, 6, w - 6 - 150 - 5 - BTN - 6 - 5, BTN)
    entry:initialise()
    p:addChild(entry)
    local combo = ISComboBox:new(w - BTN - 6 - 150 - 5, 6, 150, BTN)
    combo:initialise()
    combo:addOption("Recipe Name")
    p:addChild(combo)
    local viewBtn = ISButton:new(w - BTN - 6, 6, BTN, BTN, "", p, function() end)
    viewBtn:initialise()
    p:addChild(viewBtn)
    local sortCombo = ISComboBox:new(w - BTN - 6 - 150 - 5, 6 + BTN + 5, 150, BTN)
    sortCombo:initialise()
    sortCombo:addOption("Alphabetical (A-Z)")
    p:addChild(sortCombo)
    local tick = ISPanel:new(6, 6 + BTN + 5, 200, BTN)
    tick.Type = "ISTickBox"
    tick.background = false
    tick:initialise()
    tick.render = function(self)
        self:drawRect(0, 4, 14, 14, 1, 0.2, 0.2, 0.2)
        self:drawText("Show All Recipes", 20, 3, 1, 1, 1, 1, UIFont.NewSmall)
    end
    p:addChild(tick)
    return p
end

-- ── recipe list: doDrawNode/doDrawGroup anatomy (spec §4) ────────────────
local function mkRecipeList(x, y, w, h)
    local p = ISPanel:new(x, y, w, h)
    p.background = false
    p:initialise()
    -- itemheight = max(2 + FH + FH + 10, 32 + 10)
    p.itemheight = math.max(2 + FH + FH + 10, 42)
    p.selected = 2
    p.selectedColor = { r = 0.7, g = 0.35, b = 0.15, a = 0.3 }
    p.mouseOverColor = { r = 0.9, g = 0.9, b = 0.9, a = 0.1 }
    p.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    p.doDrawItem = function() end
    p.starSetTexture = tex("media/ui/inventoryPanes/FavouriteYes.png")
    p.rows = {
        { name = "Add Cigarette to Pack", icon = "Item_Cigarettes", craftable = true, fav = true,
          desc = "(tags: InHandCraft,CanBeDoneInDark)", props = { "Walking" } },
        { name = "Add Timer to Bomb", icon = "Item_Timer", craftable = false,
          desc = "(tags: AnySurfaceCraft)", skill = "Requires Electrical Level 2", good = false,
          props = { "Walking", "Light", "Surface" } },
        { group = "Assemble", arrow = true },
        { name = "Assemble Crude Knife", icon = "Item_KitchenKnife", craftable = true, ingroup = true,
          desc = "(tags: InHandCraft)", skill = "Requires Maintenance Level 1", good = true,
          props = { "Light" } },
    }
    p.render = function(self)
        local yy = 0
        local safeW = self.width - 13
        for i, row in ipairs(self.rows) do
            local xoff = row.ingroup and 32 or 0
            -- vanilla grows the row: usedHeight = max(itemheight, content)
            local lines = row.group and 1 or (2 + (row.skill and 1 or 0))
            local rh = math.max(self.itemheight, 4 + lines * FH + 10)
            if row.group then rh = self.itemheight end
            if i == self.selected then
                local sc = self.selectedColor
                self:drawRect(0, yy, self.width, rh - 1, sc.a, sc.r, sc.g, sc.b)
            end
            self:drawRectBorder(0, yy, self.width, rh, 0.5,
                self.borderColor.r, self.borderColor.g, self.borderColor.b)
            local iconY = yy + math.floor(rh / 2) - 16
            if row.group then
                local gi = tex("media/ui/craftingMenus/BuildProperty_Surface.png")
                if gi then self:drawTextureScaledAspect(gi, 10, iconY, 32, 32, 1, 1, 1, 0.5) end
                local ar = tex("media/ui/Icon_RecipeGroup_Open_48x48.png")
                if ar then self:drawTextureScaledAspect(ar, 18, iconY + 8, 16, 16, 1, 1, 1, 1) end
                self:drawText(row.group, 52, yy + 4, 1, 1, 1, 1, UIFont.Small)
            else
                local c = row.craftable and 1.0 or 0.5
                local ic = tex(row.icon)
                if ic then self:drawTextureScaledAspect(ic, 10 + xoff, iconY, 32, 32, c, c, c, 1) end
                if row.fav and self.starSetTexture then
                    self:drawTextureScaledAspect(self.starSetTexture, 10 + xoff, iconY + 22, 10, 10, 1, 0, 0.8, 0)
                end
                local dl = 52 + xoff
                self:drawText(row.name, dl, yy + 4, c, c, c, 1, UIFont.Small)
                self:drawText(row.desc, dl, yy + 4 + FH, 0.5, 0.5, 0.5, 1, UIFont.Small)
                if row.skill then
                    if row.good then self:drawText(row.skill, dl, yy + 4 + FH * 2, 0, 0.8, 0, 1, UIFont.Small)
                    else self:drawText(row.skill, dl, yy + 4 + FH * 2, 0.8, 0, 0, 1, UIFont.Small) end
                end
                -- sub-property icon strip, right-aligned, walking left
                local ir = safeW - 10 - 8 - 2
                for _, pr in ipairs(row.props or {}) do
                    local pt = tex("media/ui/craftingMenus/BuildProperty_" .. pr .. "_16.png")
                    if pt then self:drawTextureScaledAspect(pt, ir, yy + 4, 16, 16, c, c, c, 1) end
                    ir = ir - 18
                end
            end
            yy = yy + rh
        end
    end
    return p
end

-- ── detail column: title header / Required tiles / control strip ────────
local function mkDetail(x, y, w, h)
    local p = ISPanel:new(x, y, w, h)
    p.background = false
    p:initialise()
    p.render = function(self)
        -- ISWidgetTitleHeader: 48 icon, Small title at icon.right+15,
        -- property icons 16 right-aligned at y=5, fav BUTTON at icon BL,
        -- red error label under the text stack
        local ic = tex("Item_Cigarettes")
        if ic then self:drawTextureScaledAspect(ic, 10, 8, 48, 48, 1, 1, 1, 1) end
        local fav = tex("media/ui/inventoryPanes/FavouriteYes.png")
        if fav then self:drawTextureScaledAspect(fav, 5, 45, 16, 16, 1, 0, 0.8, 0) end
        self:drawText("Add Cigarette to Pack", 73, 10, 1, 1, 1, 1, UIFont.Small)
        self:drawText("( DBG:AddACigarette)", 73, 10 + FH, 0.9, 0.9, 0.9, 1, UIFont.NewSmall)
        self:drawText("Can't craft: missing required item(s)", 73, 10 + FH * 2, 0.8, 0, 0, 1, UIFont.NewSmall)
        local ir = self.width - 16 - 7
        for _, pr in ipairs({ "Surface", "Book", "Light", "Walking", "Clock" }) do
            local pt = tex("media/ui/craftingMenus/BuildProperty_" .. pr .. "_16.png")
            if pt then self:drawTextureScaledAspect(pt, ir, 5, 16, 16, 1, 1, 1, 1) end
            ir = ir - 21
        end
        -- ISWidgetIngredientsInputs: label + 4-col tile grid
        self:drawText("Required Items", 6, 80, 1, 1, 1, 1, UIFont.Small)
        local tiles = {
            { icon = "Item_Cigarettes", n = "0/1", ok = false },
            { icon = "Item_CigarettePack", n = "0/1", ok = false },
        }
        local ba = (self.backgroundColor and self.backgroundColor.a or 1)
        for i, t in ipairs(tiles) do
            local tx = 5 + (i - 1) * 69
            self:drawRect(tx, 80 + FH + 5, 64, 64, 0.6 * ba, 0.05, 0.05, 0.05)
            if t.ok then self:drawRectBorder(tx, 80 + FH + 5, 64, 64, 1, 0.2, 0.7, 0.2)
            else self:drawRectBorder(tx, 80 + FH + 5, 64, 64, 1, 0.8, 0.15, 0.1) end
            local it = tex(t.icon)
            if it then self:drawTextureScaledAspect(it, tx + 16, 80 + FH + 9, 32, 32, 1, 1, 1, 1) end
            self:drawText(t.n, tx + 22, 80 + FH + 45, 0.9, 0.9, 0.9, 1, UIFont.NewSmall)
        end
    end
    -- ISWidgetHandCraftControl (spec §7): quantity cluster | duration +
    -- progress bar, then FULL-WIDTH Craft (+ Force Action, debug)
    local ch = BTN * 3 + 5 * 2 + 5 * 3 + 2
    local ctrl = ISPanel:new(0, h - ch, w, ch)
    ctrl:setBackgroundColor(0.2, 0.2, 0.2, 0.5)
    ctrl.background = true
    ctrl.Type = "ISWidgetHandCraftControl"
    ctrl:initialise()
    ctrl.render = function(self)
        self:drawText("Quantity:", 6, 8, 1, 1, 1, 1, UIFont.Small)
        self:drawText("Time Required: 00m 25s", math.floor(self.width / 2), 8, 1, 1, 1, 1, UIFont.Small)
    end
    local qx = 6 + 70 + 5
    local less = ISButton:new(qx, 6, BTN, BTN, "-", ctrl, function() end)
    less:initialise(); ctrl:addChild(less)
    local entry = ISTextEntryBox:new("0", qx + BTN + 5, 6, 55, BTN)
    entry:initialise(); ctrl:addChild(entry)
    local more = ISButton:new(qx + BTN + 5 + 55 + 5, 6, BTN, BTN, "+", ctrl, function() end)
    more:initialise(); ctrl:addChild(more)
    local maxb = ISButton:new(qx + BTN * 2 + 5 * 2 + 55 + 5, 6, 44, BTN, "MAX", ctrl, function() end)
    maxb:initialise(); ctrl:addChild(maxb)
    local barX = math.floor(w / 2) + 165
    local bar = ISPanel:new(barX, 6, w - barX - 11, BTN)
    bar.Type = "ISProgressBar"
    bar.background = false
    bar.progress = 0.6
    bar.progressColor = { r = 0.2, g = 0.7, b = 0.2, a = 1 }
    bar:initialise()
    bar.render = function(self)
        self:drawRect(0, 0, self.width, self.height, 1, 0.1, 0.1, 0.1)
        local pc = self.progressColor
        self:drawRect(0, 0, math.floor(self.width * self.progress), self.height, pc.a or 1, pc.r, pc.g, pc.b)
    end
    ctrl:addChild(bar)
    local craft = ISButton:new(6, 6 + BTN + 5, w - 12, BTN, "Craft", ctrl, function() end)
    craft:initialise(); ctrl:addChild(craft)
    local force = ISButton:new(6, 6 + BTN * 2 + 10, w - 12, BTN, "Force Action", ctrl, function() end)
    force:initialise(); ctrl:addChild(force)
    p:addChild(ctrl)
    return p
end

function CraftInv.build()
    local SIR = _G.SauceInvRender
    SIR.Guard = SIR.Guard or { tripped = {}, trip = function() end }

    local W, H = 1024, 560
    local win = ISCollapsableWindow:new(10, 10, W, H)
    win:setTitle("")
    win:initialise()
    function win:titleBarHeight() return 16 end
    win.backgroundColor = win.backgroundColor or { a = 0.8 }
    win.borderColor = win.borderColor or { a = 1 }

    local hdr = mkHeader(W)
    win:addChild(hdr)
    local top = 16 + 46 + 5
    local colH = H - top - 10
    local cats = mkCategories(5, top, colH)
    cats.Type = "ISWidgetRecipeCategories"
    win:addChild(cats)
    -- recipes column (fill): filter strip + list, spec: filter atop list
    local rx, rw = 5 + 125 + 5, W - 5 - 125 - 5 - 5 - 515 - 5
    local filt = mkFilter(rx, top, rw)
    filt.Type = "ISWidgetRecipeFilterPanel"
    win:addChild(filt)
    local recipes = mkRecipeList(rx, top + filt.height + 5, rw, colH - filt.height - 5)
    recipes.Type = "ISWidgetRecipesPanel"
    win:addChild(recipes)
    local detail = mkDetail(W - 515 - 5, top, 515, colH)
    detail.Type = "ISCraftRecipePanel"
    win:addChild(detail)

    local origPrerender = win.prerender
    win.prerender = function(self)
        local ok, err = pcall(function() SIR.CraftDress.dressPre(self) end)
        if not ok then SIR.Guard.trip("craftdress", err) end
        origPrerender(self)
    end

    win._scene = { cats = cats, recipes = recipes, detail = detail, header = hdr }
    return win
end

return CraftInv
