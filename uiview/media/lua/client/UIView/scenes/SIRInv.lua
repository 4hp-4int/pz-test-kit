--[[
    UIView scene — SauceInvRender (SIR) inventory rendering
    =======================================================
    Drives the REAL SIR.renderdetails (the ISInventoryPane.renderdetails
    replacement) over a column of mock item stacks, so the inventory visuals
    (condition bars, status/alert badges, category icons, literature states) can be
    inspected + iterated headlessly — the inventory-side analog of PaletteStates.

    Strategy: SIR.renderdetails reads a big ISInventoryPane surface, but almost all
    of it is stubbable. We give it a pane whose draw* calls record to the UIView
    Recorder (via ISPanel), pre-build self.itemslist (skip refreshContainer), and
    stub the scroll/drag/stencil plumbing as no-ops. Items are mocked with a
    catch-all metatable so any SIR getter we didn't set returns nil safely; the
    handful that drive a visual (condition, food state, literature, attachments)
    are set per archetype.
]]

require "ISUI/ISPanel"
-- SIR render chain (load order mirrors sir_main, minus the hook-wiring modules)
require "sir_icons"
require "sir_colors"
require "sir_cache"
require "sir_dupes"
require "sir_layout"
require "sir_providers"
require "sir_icon_overlay"   -- wraps UIMock's ISInventoryItem.renderItemIcon to overlay condition bars
require "sir_details"
require "sir_render"
require "sir_search"         -- SIRSearchBar (real SIR search + category chips)
require "sir_window"         -- full-window ledger dress (hooks the real ISInventoryPage)
require "sir_craftindex"     -- craft reverse-index (skill-lens relevance; mocked below)
require "sir_lens"           -- lens engine (Combat lane microcharts)

local SIR = _G.SauceInvRender
local Scene = {}

-- ---- global stubs the SIR render path expects (set only if absent) ---------
local function ensureGlobals()
    if type(getPlayerHotbar) ~= "function" then
        function getPlayerHotbar() return { isInHotbar = function() return false end } end
    end
    if type(getSandboxOptions) ~= "function" then
        function getSandboxOptions()
            return { getOptionByName = function() return { getValue = function() return false end } end }
        end
    end
    if type(getZomboidRadio) ~= "function" then
        function getZomboidRadio()
            return { getRecordedMedia = function() return { hasListenedToAll = function() return false end } end }
        end
    end
    if type(getTimeInMillis) ~= "function" then function getTimeInMillis() return 0 end end
    -- globals the real ISInventoryPage chrome calls
    if type(round) ~= "function" then function round(n) return n end end
    if type(isClient) ~= "function" then function isClient() return false end end
    if BUTTON_HGT == nil then BUTTON_HGT = 20 end
    if type(getPlayerInventory) ~= "function" then function getPlayerInventory() return nil end end
    -- Make the category column read like in-game: turn the IGUI_ItemCat_<X> keys
    -- (the harness has no vanilla item-category translations) into "<X>". Delegates
    -- everything else to the original getText, so other tests are unaffected.
    if not _G._sirGetTextWrapped then
        local orig = getText
        _G.getText = function(key, ...)
            if type(key) == "string" then
                local cat = key:match("^IGUI_ItemCat_(.+)$")
                if cat then return cat end
            end
            return orig(key, ...)
        end
        _G._sirGetTextWrapped = true
    end
    -- _type-based instanceof (matches the harness convention) so the lens's
    -- instanceof(item,"HandWeapon") gating resolves headlessly.
    if type(instanceof) ~= "function" then
        function instanceof(o, c) return type(o) == "table" and o._type == c end
    end
    if ItemTag == nil then ItemTag = setmetatable({}, { __index = function() return {} end }) end
    if ItemType == nil then ItemType = setmetatable({}, { __index = function() return {} end }) end
    if Fluid == nil then Fluid = setmetatable({}, { __index = function() return {} end }) end
    -- Real SkillBook entries so the literature state machine actually runs
    -- (skill -> perk lookup). Unknown skills still fall through to nil.
    if SkillBook == nil or not SkillBook.Carpentry then
        SkillBook = setmetatable({
            Carpentry = { perk = "Woodwork" },
            Electrical = { perk = "Electricity" },
            Metalworking = { perk = "Blacksmith" },
        }, { __index = function() return nil end })
    end
    -- ISInventoryItem.renderItemIcon is provided by UIMock and wrapped by
    -- sir_icon_overlay; nothing to stub here.
    if UIManager == nil then UIManager = {} end
    if type(UIManager.getMillisSinceLastRender) ~= "function" then
        UIManager.getMillisSinceLastRender = function() return 16 end
    end
    -- The real craft index reads PZ's recipe DB (absent headless); mock role()
    -- by fullType so the skill-lens RENDER can be verified in uiview.
    local SIR = _G.SauceInvRender
    if SIR and SIR.Craft then
        local MOCK = {
            woodwork = {
                ["Base.Saw"] = "tool", ["Base.Hammer"] = "tool",
                ["Base.Screwdriver"] = "tool", ["Base.Axe"] = "tool",
                ["Base.Plank"] = "mat", ["Base.Log"] = "mat",
                ["Base.Nails"] = "mat", ["Base.Woodglue"] = "mat",
                ["Base.BookCarpentry1"] = "book", ["Base.BookCarpentry2"] = "book",
                ["Base.BookCarpentry3"] = "book", ["Base.VHS_Home"] = "book",
            },
            blacksmith = {}, welding = {},
        }
        SIR.Craft.role = function(item, gid)
            local ft; pcall(function() ft = item:getFullType() end)
            return (MOCK[gid] or {})[ft]
        end
    end
end

-- ---- mock player -----------------------------------------------------------
-- sharedInv lets the page's weight readout see the pane's inventory as the
-- player's own (the `inventory == player:getInventory()` check).
-- fullTypes the player has already finished — drives the "read" (green check)
-- state for both recipe magazines and fully-read skill books.
local READ_FULLTYPES = { ["Base.BookElectrical1"] = true }

local function mockPlayer(sharedInv)
    local readBooks = { contains = function(_, ft) return READ_FULLTYPES[ft] == true end }
    return setmetatable({
        getPlayerNum     = function() return 0 end,
        isEquipped       = function(_, it) return it and it._equipped or false end,
        getPerkLevel     = function() return 2 end,
        getAlreadyReadPages = function(_, ft) return READ_FULLTYPES[ft] and 9999 or 0 end,
        getAlreadyReadBook  = function() return readBooks end,
        isLiteratureRead = function() return false end,
        isPrintMediaRead = function() return false end,
        hasReadMap       = function() return false end,
        isKnownPoison    = function() return false end,
        getMaxWeight     = function() return 12 end,
        -- equipped weapon for the Combat-lens vs-equipped delta (dmg 0.7 baseline)
        getPrimaryHandItem = function() return { _type = "HandWeapon", getMaxDamage = function() return 0.7 end } end,
        getInventory     = function() return sharedInv or { getItems = function() return { size = function() return 0 end } end } end,
    }, { __index = function() return function() return nil end end })
end

-- ---- mock item -------------------------------------------------------------
local _id = 0
local function nextId() _id = _id + 1; return _id end
local NILFN = function() return function() return nil end end   -- catch-all: any unset getter -> nil

-- o = { name, fullType, cat, displayCat, class("HandWeapon"/"Food"/"Literature"/
--       "InventoryContainer"/...), ranged, cond, condMax, sharpness, headCond,
--       headCondMax, foodState("rotten"/"burnt"/"frozen"), pages, skill, skillLvl,
--       maxLvl, fav, equipped, broken, weight, tex }
local function mockItem(o)
    o = o or {}
    local id = nextId()
    -- getTex returns a getTexture stub; its name ("Item_<X>") is recorded by the
    -- Recorder, and build_view.py extracts the REAL pixels from the game's .pack
    -- files — so the pane renders with actual in-game icons.
    local tex = o.tex
    if tex == nil and o.icon then tex = getTexture(o.icon) end
    local base = {
        _type           = o.class or "InventoryItem",
        _equipped       = o.equipped or false,
        getID           = function() return id end,
        getFullType     = function() return o.fullType or ("Base.Item" .. id) end,
        getName         = function() return o.name or "Item" end,
        getDisplayName  = function() return o.name or "Item" end,
        getType         = function() return o.fullType or ("Item" .. id) end,
        getCategory     = function() return o.cat or "Item" end,
        getDisplayCategory = function() return o.displayCat or o.cat end,
        getCondition    = function() return o.cond or 0 end,
        getConditionMax = function() return o.condMax or 0 end,
        hasHeadCondition = function() return o.headCond ~= nil end,
        getHeadCondition = function() return o.headCond or 0 end,
        getHeadConditionMax = function() return o.headCondMax or 10 end,
        hasSharpness    = function() return o.sharpness ~= nil end,
        getSharpness    = function() return o.sharpness or 0 end,
        getMaxSharpness = function() return o.sharpnessMax or 1 end,
        -- Combat-lens getters (real B42 names): damage + ammo gauge
        getMaxDamage        = function() return o.dmg or 0 end,
        getMaxAmmo          = function() return o.ammoMax or 0 end,
        getCurrentAmmoCount = function() return o.ammo or 0 end,
        getCriticalChance   = function() return o.crit or 0 end,
        -- Survival-lens getters: decay timing + nutrition + drainable doses
        getRottenTime       = function() return o.rottenTime or 0 end,
        getAge              = function() return o.age or 0 end,
        getHungerChange     = function() return o.hunger or 0 end,
        getCalories         = function() return o.cal or 0 end,
        getCurrentUsesFloat = function() return o.uses end,
        -- Logistics-lens getters: container capacity/fill
        getCapacity         = function() return o.cap or 0 end,
        getContentsWeight   = function() return o.contents or 0 end,
        isBroken        = function() return o.broken or false end,
        isRanged        = function() return o.ranged or false end,
        isRotten        = function() return o.foodState == "rotten" end,
        isBurnt         = function() return o.foodState == "burnt" end,
        isFrozen        = function() return o.foodState == "frozen" end,
        getNumberOfPages = function() return o.pages or -1 end,
        -- recipe magazines: non-empty teached list drives the "recipe" book state
        -- (info-"i" when un-learned, green check once read).
        getTeachedRecipes = function()
            if o.recipes then return { isEmpty = function() return false end } end
            return { isEmpty = function() return true end }
        end,
        getSkillTrained = function() return o.skill end,
        getLvlSkillTrained = function() return o.skillLvl or -1 end,
        getMaxLevelTrained = function() return o.maxLvl or 0 end,
        isFavorite      = function() return o.fav or false end,
        isEquipped      = function() return o.equipped or false end,
        getAttachedSlot = function() return o.attachedSlot end,
        getActualWeight = function() return o.weight or 0.4 end,
        -- heat is read numerically (math.abs) for food/combo rows; 1 = room temp,
        -- which short-circuits the heat-tint branch unless a test opts in.
        getHeat         = function() return o.heat or 1 end,
        getItemHeat     = function() return o.itemHeat or o.heat or 1 end,
        getInvHeat      = function() return o.invHeat or 0 end,
        getTex          = function() return tex end,
        getTexture      = function() return tex end,
        getModData      = function() return o.modData or {} end,
        hasModData      = function() return o.modData ~= nil end,
        getJobDelta     = function() return o.jobDelta or 0 end,
        getInventory    = function() return o.inv end,
        updateAge       = function() end,
        updateWetness   = function() end,
    }
    return setmetatable(base, { __index = NILFN })
end

-- ---- mock pane (ISInventoryPane stand-in that records via ISPanel) ----------
local function mockPane(stacks, opts)
    opts = opts or {}
    local w = opts.width or 380
    local rowH = opts.itemHgt or 36
    local h = opts.height or (#stacks * rowH + 8)

    local pane = ISPanel:new(0, 0, w, h)
    pane:initialise()
    pane.Type = "SIR_InventoryPane"

    -- geometry / state SIR.renderdetails reads
    pane.itemslist   = stacks
    pane.items       = {}
    pane.inventory   = { isDrawDirty = function() return false end,
                         getItems = function() return { size = function() return 0 end } end }
    pane.itemHgt     = rowH
    pane.headerHgt   = opts.headerHgt or 0
    pane.height      = h
    pane.width       = w
    -- column2 = icon|name divider (icon sits left of it), column3 = name|category
    -- divider, column4 = right edge. Spaced so name + category don't collide.
    pane.column2     = 44
    pane.column3     = w - 120
    pane.column4     = w
    pane.selected    = {}
    pane.collapsed   = {}
    pane.highlightItem = nil
    pane.mouseOverOption = 0
    pane.doController = false
    pane.joyselection = 0
    pane.player      = 0
    -- parent carries onCharacter (renderdetails reads it) AND the position methods
    -- UIMock's getAbsoluteX/Y walk up to (else they call nil on a plain table).
    pane.parent      = { onCharacter = opts.onCharacter ~= false,
                         getAbsoluteX = function() return 0 end,
                         getAbsoluteY = function() return 0 end }
    pane.dragging    = false
    pane.dragStarted = false
    pane.font        = UIFont.Small
    pane.fontHgt     = 14
    pane.hotbar      = nil

    -- plumbing stubs
    function pane:updateScrollbars() end
    function pane:refreshContainer() end
    function pane:getMouseX() return -1 end
    function pane:getMouseY() return -1 end
    function pane:getYScroll() return 0 end
    function pane:getHeight() return self.height end
    function pane:isVScrollBarVisible() return false end
    function pane:setScrollHeight() end
    function pane:setScrollWidth() end
    function pane:drawRectStatic(x, y, ww, hh, a, r, g, b) self:drawRect(x, y, ww, hh, a, r, g, b) end

    -- the frame driver (walk) calls :render -> the real SIR pipeline
    function pane:render()
        SIR.renderdetails(self, false)
        -- column-header labels: in-game these are vanilla's nameHeader/typeHeader
        -- sort buttons (pane children); the harness has no such children, so draw
        -- facsimiles in the header band SIR now paints.
        if self.headerHgt and self.headerHgt > 0 then
            local hi = (require "sir_theme").ink.head
            self:drawText("Name", self.column2 + 8, 1, hi[1], hi[2], hi[3], hi[4], UIFont.Small)
            self:drawText("Category", self.column3 + 8, 1, hi[1], hi[2], hi[3], hi[4], UIFont.Small)
            -- vanilla header filter buttons (expand-all + filter-menu) in the icon
            -- column. In-game these are real ISButtons on the pane; drawn here.
            local bh = self.headerHgt
            -- expand-all (caret)
            self:drawRect(1, 1, bh - 2, bh - 2, 0.30, 0.42, 0.42, 0.48)
            self:drawTextureScaledAspect(getTexture("sir_caret-down"), 3, 3, bh - 6, bh - 6, 0.9, 1, 1, 1)
            -- filter-menu (funnel glyph: 3 decreasing lines)
            local fx = bh + 1
            self:drawRect(fx, 1, bh - 2, bh - 2, 0.30, 0.42, 0.42, 0.48)
            self:drawRect(fx + 3, 5, 7, 1, 0.85, 0.82, 0.82, 0.86)
            self:drawRect(fx + 4, 8, 5, 1, 0.85, 0.82, 0.82, 0.86)
            self:drawRect(fx + 5, 11, 3, 1, 0.85, 0.82, 0.82, 0.86)
        end
    end
    function pane:prerender() end

    return pane
end

-- ---- a representative stack of item archetypes -----------------------------
local function stack(item, o)
    o = o or {}
    return { items = { item }, name = item:getName(), count = o.count or 1, equipped = o.equipped or false }
end

local function archetypes()
    return {
        stack(mockItem({ name = "Pistol",        icon = "Item_Revolver", fullType = "Base.Pistol", class = "HandWeapon",
                         cat = "Weapon", ranged = true, cond = 7, condMax = 10, equipped = true,
                         dmg = 0.9, ammo = 12, ammoMax = 15, crit = 0.35 }), { equipped = true }),
        stack(mockItem({ name = "Hunting Knife",  icon = "Item_HuntingKnife", fullType = "Base.HuntingKnife", class = "HandWeapon",
                         cat = "Weapon", displayCat = "SmallBlade", sharpness = 0.8, sharpnessMax = 1, cond = 9, condMax = 10,
                         dmg = 0.6 })),
        stack(mockItem({ name = "Baseball Bat",    icon = "Item_BaseballBat", fullType = "Base.BaseballBat", class = "HandWeapon",
                         cat = "Weapon", cond = 4, condMax = 10, dmg = 1.5 })),
        stack(mockItem({ name = "Apple",          icon = "Item_Apple", fullType = "Base.Apple", class = "Food", cat = "Food",
                         rottenTime = 10, age = 2, hunger = -15, cal = 50, weight = 0.3 }), { count = 3 }),
        stack(mockItem({ name = "Rotten Steak",   icon = "Item_Steak", fullType = "Base.Steak", class = "Food", cat = "Food", foodState = "rotten",
                         rottenTime = 10, age = 9.4, hunger = -40, cal = 220, weight = 0.5 })),
        stack(mockItem({ name = "Canned Peas",    icon = "Item_CannedPeas", fullType = "Base.TinnedPeas", class = "Food", cat = "Food", foodState = "frozen",
                         rottenTime = 0, hunger = -25, cal = 180, weight = 0.6 })),
        stack(mockItem({ name = "Carpentry Vol.2",icon = "Item_Book", fullType = "Base.BookCarpentry2", class = "Literature",
                         cat = "Literature", displayCat = "SkillBook", pages = 220, skill = "Carpentry", skillLvl = 2, maxLvl = 3 })),
        -- skill too HIGH to learn yet -> amber lock badge (the legibility case)
        stack(mockItem({ name = "Blacksmith Vol.3",icon = "Item_Book", fullType = "Base.BookMetalwork3", class = "Literature",
                         cat = "Literature", displayCat = "SkillBook", pages = 180, skill = "Metalworking", skillLvl = 5, maxLvl = 6 })),
        -- recipe magazine you HAVEN'T learned -> info "i" ("still something here")
        stack(mockItem({ name = "Carpentry Mag",  icon = "Item_Magazine", fullType = "Base.MagazineCarpentry",
                         class = "Literature", cat = "Literature", recipes = true })),
        -- recipe book you've already read -> green check ("done, ignore")
        stack(mockItem({ name = "Electrical Vol.1",icon = "Item_Magazine_Electric", fullType = "Base.BookElectrical1",
                         class = "Literature", cat = "Literature", recipes = true })),
        stack(mockItem({ name = "Bandage",        icon = "Item_Bandage", fullType = "Base.Bandage", class = "Drainable", cat = "FirstAid", displayCat = "FirstAid",
                         medical = true, uses = 0.6, weight = 0.1 })),
        stack(mockItem({ name = "Duffel Bag",     icon = "Item_Duffelbag", fullType = "Base.Bag_DuffelBag", class = "InventoryContainer", cat = "Container",
                         cap = 20, contents = 8.4, weight = 1.2 })),
        -- a saw is a HandWeapon but PZ's displayCategory is "ToolWeapon" -> show
        -- the TOOL glyph, not a weapon subtype (the saw-reads-as-club bug).
        stack(mockItem({ name = "Hand Saw",       icon = "Item_Handsaw", fullType = "Base.Saw", class = "HandWeapon", cat = "Tool", displayCat = "ToolWeapon", cond = 6, condMax = 10 })),
        stack(mockItem({ name = "Planks",         icon = "Item_Plank", fullType = "Base.Plank", class = "Item", cat = "Material", weight = 0.8 }), { count = 6 }),
    }
end

-- A carpentry-heavy bag, for the PROFESSION-lens promo shot. A real carpenter's
-- kit, all canonical B42 items: the Home VHS tapes + Carpentry skill books (the
-- two ways to learn it), the tools, and the materials. Almost everything is
-- woodwork-relevant so the lens lights the whole list and you can see it working;
-- a pistol + apple stay dim for contrast.
local function woodworkArchetypes()
    return {
        stack(mockItem({ name = "Home VHS",        icon = "Item_Cassette3", fullType = "Base.VHS_Home", class = "Normal",
                         cat = "Entertainment", displayCat = "Entertainment", weight = 0.5 }), { count = 2 }),
        stack(mockItem({ name = "Carpentry Vol.1", icon = "Item_Book8", fullType = "Base.BookCarpentry1", class = "Literature",
                         cat = "Literature", displayCat = "SkillBook", pages = 160, skill = "Carpentry", skillLvl = 0, maxLvl = 1 })),
        stack(mockItem({ name = "Carpentry Vol.2", icon = "Item_Book8", fullType = "Base.BookCarpentry2", class = "Literature",
                         cat = "Literature", displayCat = "SkillBook", pages = 220, skill = "Carpentry", skillLvl = 2, maxLvl = 3 })),
        stack(mockItem({ name = "Carpentry Vol.3", icon = "Item_Book8", fullType = "Base.BookCarpentry3", class = "Literature",
                         cat = "Literature", displayCat = "SkillBook", pages = 260, skill = "Carpentry", skillLvl = 4, maxLvl = 5 })),
        stack(mockItem({ name = "Hammer",         icon = "Item_Hammer", fullType = "Base.Hammer", class = "HandWeapon",
                         cat = "Tool", displayCat = "ToolWeapon", cond = 9, condMax = 10 })),
        stack(mockItem({ name = "Saw",            icon = "Item_Hacksaw", fullType = "Base.Saw", class = "HandWeapon",
                         cat = "Tool", displayCat = "ToolWeapon", cond = 6, condMax = 10 })),
        stack(mockItem({ name = "Screwdriver",    icon = "Item_Screwdriver", fullType = "Base.Screwdriver", class = "HandWeapon",
                         cat = "Tool", displayCat = "ToolWeapon", cond = 8, condMax = 10 })),
        stack(mockItem({ name = "Axe",            icon = "Item_Axe", fullType = "Base.Axe", class = "HandWeapon",
                         cat = "Tool", displayCat = "ToolWeapon", cond = 7, condMax = 10 })),
        stack(mockItem({ name = "Nails",          icon = "Item_Nails", fullType = "Base.Nails", class = "Item", cat = "Material", weight = 0.01 }), { count = 50 }),
        stack(mockItem({ name = "Planks",         icon = "Item_Plank", fullType = "Base.Plank", class = "Item", cat = "Material", weight = 0.8 }), { count = 10 }),
        stack(mockItem({ name = "Logs",           icon = "Item_Logs", fullType = "Base.Log", class = "Item", cat = "Material", weight = 2.0 }), { count = 6 }),
        stack(mockItem({ name = "Wood Glue",      icon = "Item_Woodglue", fullType = "Base.Woodglue", class = "Drainable", cat = "Material", uses = 0.7, weight = 0.2 })),
        -- not woodwork — stays dim so the lens contrast reads
        stack(mockItem({ name = "Pistol",         icon = "Item_Revolver", fullType = "Base.Pistol", class = "HandWeapon",
                         cat = "Weapon", ranged = true, cond = 7, condMax = 10 })),
        stack(mockItem({ name = "Apple",          icon = "Item_Apple", fullType = "Base.Apple", class = "Food", cat = "Food", weight = 0.3 }), { count = 2 }),
    }
end

-- ---- REAL ISInventoryPage chrome around the SIR pane -----------------------
-- Loads the actual vanilla ISInventoryPage (via vanilla_requires) so the window
-- frame, title bar, weight readout etc. are the genuine article — not a mock.
-- We feed it our SIR pane as its inventoryPane (SIR replaces the pane's
-- renderdetails anyway) and skip createChildren (which would build the real
-- buttons/controls/resize widgets — a much deeper tree); the chrome only reads a
-- few geometry fields off those, which we supply directly.
local function realWindow(stacks, opts)
    opts = opts or {}
    local rowH = opts.itemHgt or 36
    local headerHgt = 15           -- vanilla reserves fontHgt+1 for the column headers
    local listH = #stacks * rowH
    local contentH = headerHgt + listH
    local W = opts.width or 340
    local titleH = 16
    local H = titleH + contentH + 12   -- + the status/resize rail (BUTTON_HGT/2+2)
    local buttonSize = 28          -- bag-tab column width

    -- shared inventory the page's weight readout compares to the player's own.
    -- Must satisfy what SIR.renderdetails reads (isDrawDirty) AND the page.
    local inv = { isDrawDirty = function() return false end,
                  getItems = function() return { size = function() return 0 end } end }
    -- the real loadWeight would iterate a container; a fixed value keeps the demo
    -- self-contained.
    ISInventoryPage.loadWeight = function() return 8.4 end
    -- ISInventoryPage overrides drawText/drawTextRight to go through self.javaObject
    -- (nil in the harness -> no text). Null the overrides so they fall through to
    -- UIMock's recording versions, and the title/weight actually render.
    ISInventoryPage.drawText = nil
    ISInventoryPage.drawTextRight = nil

    local page = ISInventoryPage:new(0, 0, W, H, inv, true, 1)   -- onCharacter = true
    page.Type = "ISInventoryPage"
    page.titleFontHgt = 14
    page.font = UIFont.Small
    page.player = 0
    page.title = opts.title or "Inventory"
    page.buttonSize = buttonSize   -- bag-tab column on the right
    page.capacity = true           -- show "weight / maxWeight"
    page.blink = false
    page.isCollapsed = false
    -- geometry-only stand-ins for the buttons createChildren normally makes
    page.infoButton = { getRight = function() return 24 end, getX = function() return 2 end }
    page.pinButton  = { getX = function() return W - 18 end }

    local th = page:titleBarHeight()
    page.sirFilter = { text = "", cat = nil }

    -- ── real SIR search bar (sir_search.lua) ───────────────────────────────
    -- The actual SIRSearchBar widget: live search box + category chips. In-game
    -- sir_search hooks the page to insert it between the title and the list; here
    -- we add it directly and shift the list/tabs down by its height.
    local searchH = 0
    if SIRSearchBar then
        local bar = SIRSearchBar:new(0, th, W, page)
        bar:initialise()
        bar:createChildren()
        searchH = bar:getHeight() or 0
        page:addChild(bar)
        page.sirSearchBar = bar
    end
    local listTop = th + searchH
    -- grow the window to fit the search band, keep the resize nub at the bottom
    H = listTop + contentH + 12   -- + the status/resize rail (BUTTON_HGT/2+2)
    page.height = H
    if page.setHeight then page:setHeight(H) end

    -- the SIR pane IS the page's inventoryPane (leaves room for the tab column),
    -- and a child so walk() renders it
    local pane = mockPane(stacks, { width = W - buttonSize, height = contentH, itemHgt = rowH,
                                    headerHgt = headerHgt, onCharacter = true })
    pane.x, pane.y = 0, listTop
    pane.inventory = inv
    page:addChild(pane)
    pane.parent = page
    page.inventoryPane = pane

    -- ── real container/bag-tab column ──────────────────────────────────────
    -- The vanilla page builds these via refreshBackpacks (enumerating the player's
    -- containers); here we place a few real ISButtons with bag icons in a panel at
    -- the right edge — the same widgets, just fed directly.
    local cbp = ISPanel:new(W - buttonSize, listTop, buttonSize, contentH)
    cbp:initialise()
    cbp.background = false
    cbp.keepSelectedButtonVisible = function() end   -- page prerender pokes this
    page:addChild(cbp)
    page.containerButtonPanel = cbp

    local tabs = opts.tabs or { page.invbasic, getTexture("Item_Duffelbag"), getTexture("Item_Schoolbag") }
    page.backpacks = {}
    for i, icon in ipairs(tabs) do
        local btn = ISButton:new(0, (i - 1) * buttonSize - 1, buttonSize, buttonSize, "", page, function() end)
        btn:initialise()
        btn:setImage(icon)
        btn.borderColor = { r = 0.4, g = 0.4, b = 0.45, a = 0.6 }
        btn.backgroundColor = (i == 1)
            and { r = 0.30, g = 0.32, b = 0.38, a = 0.9 }      -- selected tab
            or  { r = 0.10, g = 0.10, b = 0.12, a = 0.5 }
        cbp:addChild(btn)
        page.backpacks[i] = btn
    end
    page.backpackChoice = 1   -- in-game: which bag tab is active (dress washes it)

    return page, inv
end

-- ---- public: build the full inventory window + a one-state gallery ---------
function Scene.build(opts)
    ensureGlobals()
    _id = 0
    opts = opts or {}
    -- look selection (daylight default / "lamplight" = the dark kraft ledger):
    -- stub the Mod Options combo the render polls, so the look system runs its
    -- REAL apply path (T.setLook via SIR.optIndex) rather than being forced.
    local SIR = _G.SauceInvRender
    if SIR then
        SIR.Keys = SIR.Keys or {}
        local idx = (opts.look == "lamplight") and 2 or 1
        SIR.Keys["sir_look"] = { getValue = function() return idx end }
    end
    local stacks = (opts.fixture == "woodwork") and woodworkArchetypes() or archetypes()
    local page, inv = realWindow(stacks, opts)
    -- player must see the pane's inventory as its own (weight readout)
    local player = mockPlayer(inv)
    _G.getSpecificPlayer = function() return player end
    return page
end

-- pane-only build (no chrome) for focused tests
function Scene.buildPane(opts)
    ensureGlobals()
    _id = 0
    local player = mockPlayer()
    _G.getSpecificPlayer = function() return player end
    return mockPane(archetypes(), opts)
end

-- exposed for the layer-isolation probe / focused tests
Scene._mockItem = mockItem
Scene._mockPlayer = mockPlayer
Scene._ensureGlobals = ensureGlobals
Scene._mockPane = mockPane

function Scene.gallery()
    local Render = require "UIView/Render"
    local pane = Scene.build({})
    return {
        { label = "SIR inventory", caption = "condition bars, status badges, category icons",
          durationMs = 1, frame = Render.capture(pane, pane.width + 16, pane.height + 16) },
    }
end

return Scene
