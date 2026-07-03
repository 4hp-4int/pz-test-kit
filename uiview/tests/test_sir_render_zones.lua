--[[
    SIR — render zones (sir_render) the gallery scenes never reach
    ==============================================================
    The sirinv/sirlens scenes render a static, unselected, un-dragged list —
    which leaves whole zones of SIR.renderdetails dark. This file drives the
    REAL renderer through the interactive states: selection / hover / blink
    highlight, heat-tinted rows, the drag-ghost pass (+ marquee + can't-drop),
    expanded-stack child rows (recess, child icons, detail lines, job delta),
    collapsed stacks, the attached-equip resort, dupe badge injection on loot
    panes, cooking bars in all three phases, recipe stars, tainted fluid,
    accent stripes for the remaining classes, the no-chrome fallback,
    rendericons, and the max-items preset. Plus the lens cycle + icon overlay.
]]

local Assert  = PZTestKit.Assert
local Render  = require "UIView/Render"
local Recorder = require "UIView/Recorder"
local SIRInv  = require "UIView/scenes/SIRInv"

local SIR = _G.SauceInvRender
SIRInv._ensureGlobals()

local mockItem, mockPane, mockPlayer = SIRInv._mockItem, SIRInv._mockPane, SIRInv._mockPlayer

local function stk(item, count, extra)
    local s = { items = { item }, name = item:getName(), count = count or 1,
                equipped = (extra and extra.equipped) or false }
    if extra and extra.children then
        for _, c in ipairs(extra.children) do s.items[#s.items + 1] = c end
    end
    return s
end

local function paneFor(stacks, opts)
    opts = opts or {}
    _G.getSpecificPlayer = function() return opts.player or mockPlayer() end
    local pane = mockPane(stacks, opts)
    return pane
end

local function frame(pane)
    Render.frame(pane, pane.width + 16, pane.height + 16)
    return Recorder.ops
end

local function findRect(ops, pred)
    for _, o in ipairs(ops) do
        if o.op == "rect" and pred(o) then return o end
    end
    return nil
end

local function near(a, b) return math.abs((a or 0) - (b or 1e9)) < 0.02 end

local tests = {}

-- ── icon grid + presets ─────────────────────────────────────────────────────

tests["rendericons_paints_the_grid"] = function()
    local items = {}
    for i = 1, 3 do
        items[i] = mockItem({ name = "Nails" .. i, icon = "Item_Nails", fullType = "Base.RZ_N" .. i })
    end
    local pane = paneFor({}, {})
    pane.inventory = { getItems = function()
        return { size = function() return #items end, get = function(_, i) return items[i + 1] end }
    end }
    local texes = {}
    pane.drawTexture = function(self, tex, ...) texes[#texes + 1] = tostring(tex) end
    SIR.rendericons(pane)
    return Assert.equal(#texes, 3, "one icon per item in the grid")
end

tests["max_items_preset_caps_expanded_groups"] = function()
    local children = {}
    local first = mockItem({ name = "Ration", icon = "Item_Apple", fullType = "Base.RZ_Ration", class = "Food" })
    for i = 1, 14 do
        children[i] = mockItem({ name = "Ration", icon = "Item_Apple", fullType = "Base.RZ_Ration", class = "Food" })
    end
    SIR.setMaxItemsPerGroupPreset(1)   -- cap 10
    local pane = paneFor({ stk(first, 15, { children = children }) }, { height = 800 })
    frame(pane)
    local capped = #pane.items
    SIR.setMaxItemsPerGroupPreset(2)   -- default 30
    local pane2 = paneFor({ stk(first, 15, { children = children }) }, { height = 800 })
    frame(pane2)
    local ok = Assert.equal(capped, 11, "preset 1 renders first + 10 children")
    ok = Assert.equal(#pane2.items, 15, "default preset renders the whole stack") and ok
    return ok
end

-- ── refresh paths ───────────────────────────────────────────────────────────

tests["dirty_container_and_nil_itemslist_refresh"] = function()
    local pane = paneFor({ stk(mockItem({ name = "Pan", icon = "Item_Pan", fullType = "Base.RZ_Pan" })) }, {})
    local refreshed = 0
    pane.inventory = { isDrawDirty = function() return true end,
                       getItems = function() return { size = function() return 0 end } end }
    function pane:refreshContainer() refreshed = refreshed + 1 end
    frame(pane)
    local ok = Assert.equal(refreshed, 1, "dirty container triggers refreshContainer")

    local pane2 = paneFor({}, {})
    pane2.itemslist = nil
    function pane2:refreshContainer() refreshed = refreshed + 1; self.itemslist = {} end
    frame(pane2)
    ok = Assert.equal(refreshed, 2, "nil itemslist triggers refreshContainer") and ok
    return ok
end

tests["attached_item_resorts_to_equipped_and_back"] = function()
    local plain = mockItem({ name = "Plank", icon = "Item_Plank", fullType = "Base.RZ_Plank" })
    local o = { name = "Walkie", icon = "Item_Radio", fullType = "Base.RZ_Walkie", attachedSlot = 1 }
    local walkie = mockItem(o)
    local sWalkie, sPlain = stk(walkie), stk(plain)
    local pane = paneFor({ sWalkie, sPlain }, {})   -- onCharacter defaults true
    frame(pane)
    local ok = Assert.isTrue(sWalkie.equipped == true, "attached item marked equipped")
    ok = Assert.equal(pane.itemslist[2], sWalkie, "equipped stack resorted to the end") and ok

    o.attachedSlot = nil                            -- unattach live
    frame(pane)
    ok = Assert.isTrue(sWalkie.equipped == false, "unattached: equip flag handed back") and ok
    -- resort preserves relative order among the unequipped: plank first
    ok = Assert.equal(pane.itemslist[2], sWalkie, "resorted back among the unequipped") and ok
    return ok
end

-- ── row states ──────────────────────────────────────────────────────────────

tests["selection_hover_and_blink_highlight"] = function()
    local apple = mockItem({ name = "Apple", icon = "Item_Apple", fullType = "Base.RZ_Apple", class = "Food" })
    local pear = mockItem({ name = "Pear", icon = "Item_Apple", fullType = "Base.RZ_Pear", class = "Food" })
    local pane = paneFor({ stk(apple), stk(pear) }, {})
    pane.selected = { [1] = true }
    pane.mouseOverOption = 2
    local ops = frame(pane)
    local ok = Assert.notNil(findRect(ops, function(o) return near(o.a, 0.20) end), "selection wash")
    ok = Assert.notNil(findRect(ops, function(o) return near(o.a, 0.05) end), "hover wash") and ok

    local pane2 = paneFor({ stk(apple) }, {})
    pane2.highlightItem = "Base.RZ_Apple"           -- matches item:getType()
    local ops2 = frame(pane2)
    ok = Assert.notNil(pane2.blinkAlpha, "blink animation state advanced") and ok
    ok = Assert.notNil(findRect(ops2, function(o) return near(o.a, pane2.blinkAlpha or 0.5) end),
        "blink wash at the animated alpha") and ok
    return ok
end

tests["heat_tinted_rows_hot_and_cold"] = function()
    local soup = mockItem({ name = "Hot Soup", icon = "Item_Pot", fullType = "Base.RZ_Soup",
                            class = "Food", heat = 2, itemHeat = 2, invHeat = 0.6 })
    local peas = mockItem({ name = "Frozen Peas", icon = "Item_CannedPeas", fullType = "Base.RZ_Peas",
                            class = "Food", heat = 0.4, itemHeat = 0.4, invHeat = -0.5 })
    local pane = paneFor({ stk(soup), stk(peas) }, {})
    local ops = frame(pane)
    local ok = Assert.notNil(findRect(ops, function(o)
        return near(o.r, 0.6) and near(o.g, 0) and near(o.b, 0)
    end), "hot row tinted red at |invHeat|")
    ok = Assert.notNil(findRect(ops, function(o)
        return near(o.r, 0) and near(o.g, 0) and near(o.b, 0.5)
    end), "cold row tinted blue at |invHeat|") and ok

    -- hover over the hot row: the hover branch takes the heat tint too
    pane.mouseOverOption = 1
    local ops2 = frame(pane)
    ok = Assert.notNil(findRect(ops2, function(o)
        return near(o.a, 0.3) and near(o.r, 0.6) and near(o.g, 0)
    end), "hovered hot row keeps the heat tint") and ok
    return ok
end

tests["itemsToHighlight_draw_and_stale_owner_clear"] = function()
    local apple = mockItem({ name = "Apple", icon = "Item_Apple", fullType = "Base.RZ_HApple", class = "Food" })
    local pane = paneFor({ stk(apple) }, {})
    pane.itemsToHighlight = { [apple] = true }
    pane.itemsToHighlightOwner = { isReallyVisible = function() return true end }
    local ops = frame(pane)
    local ok = Assert.notNil(findRect(ops, function(o) return near(o.a, 0.3) and near(o.r, 1) and near(o.g, 1) and near(o.b, 1) end),
        "highlight wash for itemsToHighlight")

    pane.itemsToHighlightOwner = { isReallyVisible = function() return false end }
    frame(pane)
    ok = Assert.isNil(pane.itemsToHighlight, "stale owner clears the highlight set") and ok
    return ok
end

-- ── expanded stacks + collapsed ────────────────────────────────────────────

tests["expanded_stack_children_recess_icons_details"] = function()
    local function knife(job)
        local it = mockItem({ name = "Knife", icon = "Item_HuntingKnife", fullType = "Base.RZ_Knife",
                              class = "HandWeapon", cond = 6, condMax = 10, dmg = 0.6 })
        it.getMinDamage = function() return 0.3 end   -- the shared mock lacks it
        it.getJobDelta = function() return job or 0 end
        return it
    end
    local first = knife()
    local pane = paneFor({ stk(first, 3, { children = { knife(), knife(0.5) } }) }, { height = 300 })
    local ops = frame(pane)
    local T = require "sir_theme"
    local rc = T.ink.recess
    local ok = Assert.notNil(findRect(ops, function(o) return near(o.a, rc[4]) end), "child-row recess wash")
    ok = Assert.equal(#pane.items, 3, "first + both children in the items list") and ok
    -- job delta rect on the working child (alpha 0.2, blue-green)
    ok = Assert.notNil(findRect(ops, function(o)
        return near(o.a, 0.2) and near(o.r, 0.4) and near(o.b, 0.3)
    end), "job progress wash on the child") and ok
    -- child detail line (weapon provider) painted text beyond the name column
    local sawDetail = false
    for _, o in ipairs(ops) do
        if o.op == "text" and tostring(o.str):find("Dmg:", 1, true) then sawDetail = true end
    end
    ok = Assert.isTrue(sawDetail, "child rows carry the weapon detail line") and ok
    return ok
end

tests["child_detail_fallback_weight_line"] = function()
    local first = mockItem({ name = "Oddball", icon = "Item_Plank", fullType = "Base.RZ_Odd", weight = 1.4 })
    local child = mockItem({ name = "Oddball", icon = "Item_Plank", fullType = "Base.RZ_Odd", weight = 1.4 })
    -- tall pane: the stencil model drops text past the pane edge
    local pane = paneFor({ stk(first, 3, { children = { child } }) }, { height = 200 })
    local origResolve = SIR.resolveDetail
    SIR.resolveDetail = function() return false end   -- force the fallback line
    local ops = frame(pane)
    SIR.resolveDetail = origResolve
    local found = false
    for _, o in ipairs(ops) do
        if o.op == "text" and tostring(o.str):find("1.4kg", 1, true) then found = true end
    end
    return Assert.isTrue(found, "unclaimed child rows fall back to name + weight")
end

tests["collapsed_stack_renders_only_first_row"] = function()
    local first = mockItem({ name = "Plank", icon = "Item_Plank", fullType = "Base.RZ_CPlank" })
    local pane = paneFor({ stk(first, 4, { children = {
        mockItem({ name = "Plank", fullType = "Base.RZ_CPlank" }),
        mockItem({ name = "Plank", fullType = "Base.RZ_CPlank" }),
        mockItem({ name = "Plank", fullType = "Base.RZ_CPlank" }),
    } }) }, {})
    pane.collapsed = { ["Plank"] = true }
    frame(pane)
    return Assert.equal(#pane.items, 1, "collapsed stack contributes one row")
end

-- ── drag pass ───────────────────────────────────────────────────────────────

local function dragPane(cantDrop)
    local axe = mockItem({ name = "Axe", icon = "Item_Axe", fullType = "Base.RZ_DragAxe",
                           class = "HandWeapon", cond = 5, condMax = 10 })
    local pane = paneFor({ stk(axe) }, {})
    pane.selected = { [1] = true }
    pane.dragging, pane.dragStarted = true, true
    pane.draggingX, pane.draggingY = -20, -20     -- mouse (-1,-1) -> +19px offset
    pane.draggedItems = {
        update = function() end,
        cannotDropAnyItem = function() return cantDrop or false end,
        cannotDropItem = function() return cantDrop or false end,
    }
    function pane:suspendStencil() self._suspended = true end
    function pane:resumeStencil() self._resumed = true end
    pane.prerender = function(self)
        SIR.renderdetails(self, false)   -- normal pass skips the dragged row
        SIR.renderdetails(self, true)    -- ghost pass draws it at the offset
    end
    return pane
end

tests["drag_ghost_pass_draws_offset_row"] = function()
    local pane = dragPane(false)
    pane.draggingMarquis = true
    pane.draggingMarquisX, pane.draggingMarquisY = 5, 5
    local ops = frame(pane)
    local ok = Assert.isTrue(pane._suspended == true and pane._resumed == true,
        "stencil suspended/resumed around the ghost row")
    -- the wash rect lands at the drag offset (x = 1 + 19)
    ok = Assert.notNil(findRect(ops, function(o) return o.x == 20 and near(o.a, 0.20) end),
        "ghost row wash drawn at the drag offset") and ok
    local marquee = false
    for _, o in ipairs(ops) do if o.op == "rectborder" and o.x == 5 then marquee = true end end
    ok = Assert.isTrue(marquee, "drag marquee border drawn") and ok
    return ok
end

tests["drag_cannot_drop_paints_red"] = function()
    local ops = frame(dragPane(true))
    return Assert.notNil(findRect(ops, function(o)
        return near(o.a, 0.20) and near(o.r, 1) and near(o.g, 0) and near(o.b, 0)
    end), "can't-drop ghost row is red")
end

-- ── loot pane: dupes + stripes ─────────────────────────────────────────────

tests["loot_pane_injects_dupe_badge"] = function()
    SIR.Options = SIR.Options or {}
    SIR.Options.trackDuplicates, SIR.Options.trackDuplicatesWeapons = true, true
    local owned = mockItem({ name = "Axe", icon = "Item_Axe", fullType = "Base.RZ_LootAxe",
                             class = "HandWeapon", cond = 9, condMax = 10 })
    local playerInv = { getItems = function()
        return { size = function() return 1 end, get = function() return owned end }
    end }
    local player = mockPlayer(playerInv)
    local lootAxe = mockItem({ name = "Axe", icon = "Item_Axe", fullType = "Base.RZ_LootAxe",
                               class = "HandWeapon", cond = 3, condMax = 10 })
    SIR.Dupes.scan(player)
    local pane = paneFor({ stk(lootAxe) }, { onCharacter = false, player = player })
    local ops = frame(pane)
    local found = false
    for _, o in ipairs(ops) do
        -- I.cmpWorse resolves the "arrow-down" glyph
        if o.op == "texture" and tostring(o.name):find("arrow-down", 1, true) then found = true end
    end
    return Assert.isTrue(found, "worse-copy comparison badge rendered on the loot row")
end

tests["accent_stripes_for_clothing_key_medical"] = function()
    local pane = paneFor({
        stk(mockItem({ name = "Shirt", icon = "Item_Shirt", fullType = "Base.RZ_Shirt", class = "Clothing", cond = 5, condMax = 10 })),
        stk(mockItem({ name = "Car Key", icon = "Item_Key", fullType = "Base.RZ_Key", class = "Key" })),
        stk(mockItem({ name = "Pills", icon = "Item_Pills", fullType = "Base.RZ_Pills", displayCat = "FirstAid" })),
    }, {})
    local ops = frame(pane)
    local ok = Assert.notNil(findRect(ops, function(o)
        return o.w == 2 and near(o.r, 0.3) and near(o.g, 0.55) and near(o.b, 0.95)
    end), "clothing stripe (blue)")
    ok = Assert.notNil(findRect(ops, function(o)
        return o.w == 2 and near(o.r, 0.85) and near(o.g, 0.85) and near(o.b, 0.4)
    end), "key stripe (pale yellow)") and ok
    ok = Assert.notNil(findRect(ops, function(o)
        return o.w == 2 and near(o.r, 0.95) and near(o.g, 0.35) and near(o.b, 0.5)
    end), "medical stripe (pink)") and ok
    return ok
end

-- ── zone extras ─────────────────────────────────────────────────────────────

tests["cooking_bar_amber_ready_burning"] = function()
    local function cooking(cookTime, mtc, mtb)
        local it = mockItem({ name = "Steak", icon = "Item_Steak",
                              fullType = "Base.RZ_Cook" .. cookTime, class = "Food", heat = 2 })
        it.getCookingTime = function() return cookTime end
        it.getMinutesToCook = function() return mtc end
        it.getMinutesToBurn = function() return mtb end
        return it
    end
    local pane = paneFor({ stk(cooking(30, 60, 120)), stk(cooking(60, 60, 120)), stk(cooking(90, 60, 120)) }, {})
    local ops = frame(pane)
    local ok = Assert.notNil(findRect(ops, function(o)
        return near(o.r, 1.0) and near(o.g, 0.62) and near(o.b, 0)
    end), "amber cooking bar")
    ok = Assert.notNil(findRect(ops, function(o)
        return near(o.r, 0.35) and near(o.g, 0.95) and near(o.b, 0.35)
    end), "green ready bar") and ok
    ok = Assert.notNil(findRect(ops, function(o)
        return near(o.r, 1.0) and near(o.g, 0.20) and near(o.b, 0.05)
    end), "red burning bar") and ok
    return ok
end

tests["recipe_favorite_stars"] = function()
    local noRec = mockItem({ name = "Gadget", icon = "Item_Plank", fullType = "Base.RZ_NoRec" })
    noRec.isNoRecipes = function() return true end
    local favRec = mockItem({ name = "Nails", icon = "Item_Nails", fullType = "Base.RZ_FavRec" })
    favRec.isNoRecipes = function() return false end
    favRec.isFavouriteRecipeInput = function() return true end
    local pane = paneFor({ stk(noRec), stk(favRec) }, {})
    pane.noFavoriteRecipeInputStar = getTexture("media/ui/icon_star_no")
    pane.favoriteRecipeInputStar = getTexture("media/ui/icon_star_yes")
    local ops = frame(pane)
    local no, yes = false, false
    for _, o in ipairs(ops) do
        if o.op == "texture" then
            local n = tostring(o.name)
            if n:find("star_no", 1, true) then no = true end
            if n:find("star_yes", 1, true) then yes = true end
        end
    end
    local ok = Assert.isTrue(no, "no-recipes star drawn")
    ok = Assert.isTrue(yes, "favorite-recipe star drawn") and ok
    return ok
end

tests["tainted_fluid_poison_icon"] = function()
    local origSandbox = _G.getSandboxOptions
    _G.getSandboxOptions = function()
        return { getOptionByName = function() return { getValue = function() return true end } end }
    end
    local fc = {
        isEmpty = function() return false end,
        contains = function() return true end,       -- Bleach check short-circuits
        isTainted = function() return false end,     -- cache's combo-poison probe
        getPoisonRatio = function() return 1 end,
        getAmount = function() return 1 end,
        getCapacity = function() return 2 end,
    }
    local direct = mockItem({ name = "Bad Water", icon = "Item_WaterBottle", fullType = "Base.RZ_BadWater" })
    direct.getFluidContainer = function() return fc end
    local viaWorld = mockItem({ name = "Bad Bucket", icon = "Item_Bucket", fullType = "Base.RZ_BadBucket" })
    viaWorld.getWorldItem = function() return { getFluidContainer = function() return fc end } end
    local pane = paneFor({ stk(direct), stk(viaWorld) }, {})
    local ops = frame(pane)
    _G.getSandboxOptions = origSandbox
    local n = 0
    for _, o in ipairs(ops) do
        if o.op == "texture" and tostring(o.name):find("poison", 1, true) then n = n + 1 end
    end
    return Assert.equal(n, 2, "poison icon on both the direct and world-item fluid paths")
end

tests["profiler_counters_tick"] = function()
    local orig = SIR.Profile
    SIR.Profile = { counters = { items = 0, badgesCollect = 0, badgesDrawn = 0 } }
    local pane = paneFor({ stk(mockItem({ name = "Axe", icon = "Item_Axe", fullType = "Base.RZ_ProfAxe",
                                          class = "HandWeapon", cond = 5, condMax = 10 })) }, {})
    frame(pane)
    local c = SIR.Profile.counters
    local ok = Assert.greater(c.items, 0, "items counted")
    ok = Assert.greater(c.badgesCollect, 0, "badges counted") and ok
    SIR.Profile = orig
    return ok
end

tests["no_chrome_fallback_bands"] = function()
    local C = SIR.Chrome
    local origActive = C.active
    C.active = function() return false end
    local pane = paneFor({ stk(mockItem({ name = "Axe", icon = "Item_Axe", fullType = "Base.RZ_FlatAxe",
                                          class = "HandWeapon", cond = 5, condMax = 10 })) },
                         { headerHgt = 15 })
    local ops = frame(pane)
    C.active = origActive
    local ok = Assert.isTrue(pane._sirChrome == false, "chrome path stood down")
    ok = Assert.notNil(findRect(ops, function(o)
        return near(o.a, 0.6) and near(o.r, 0) and near(o.g, 0) and near(o.b, 0)
    end), "flat black icon-column band") and ok
    return ok
end

-- ── lens + icon overlay dregs ───────────────────────────────────────────────

tests["lens_cycle_wraps_to_off"] = function()
    local L = SIR.Lens
    L.set(0)
    local n = #L.list
    local seen = 0
    for _ = 1, n do
        if L.cycle() then seen = seen + 1 end
    end
    local ok = Assert.equal(seen, n, "cycle visits every lens")
    ok = Assert.isNil(L.cycle(), "then wraps back to off") and ok
    L.set(0)
    return ok
end

tests["combat_lens_skips_nonweapon_primary_hand"] = function()
    local L = SIR.Lens
    L.set("combat")
    local player = mockPlayer()
    player.getPrimaryHandItem = function() return { _type = "Radio" } end   -- not a HandWeapon
    local axe = mockItem({ name = "Axe", icon = "Item_Axe", fullType = "Base.RZ_LensAxe",
                           class = "HandWeapon", cond = 5, condMax = 10, dmg = 1.2 })
    local pane = paneFor({ stk(axe) }, { player = player })
    local ops = frame(pane)
    L.set(0)
    return Assert.greater(#ops, 5, "combat lane renders without a vs-equipped baseline")
end

tests["icon_overlay_draws_condition_bars_outside_sir"] = function()
    triggerEvent("OnGameStart")   -- installs the renderItemIcon hook
    local axe = mockItem({ name = "Axe", icon = "Item_Axe", fullType = "Base.RZ_OverlayAxe",
                           class = "HandWeapon", cond = 5, condMax = 10, headCond = 8, sharpness = 0.5 })
    local host = { rects = {} }
    function host:drawRect(...) self.rects[#self.rects + 1] = true end
    function host:drawTextureScaled(...) end
    function host:drawTextureScaledAspect(...) end
    function host:drawTexture(...) end
    SIR._suppressIconOverlay = false
    ISInventoryItem.renderItemIcon(host, axe, 0, 0, 1, 32, 32)
    local ok = Assert.greater(#host.rects, 5, "three condition bars painted on the icon")

    local broken = mockItem({ name = "Broke", fullType = "Base.RZ_BrokeAxe",
                              class = "HandWeapon", cond = 0, condMax = 10, broken = true })
    host.rects = {}
    ISInventoryItem.renderItemIcon(host, broken, 0, 0, 1, 32, 32)
    ok = Assert.equal(#host.rects, 0, "broken items get no overlay bars") and ok

    local book = mockItem({ name = "Book", fullType = "Base.RZ_OverlayBook", class = "Literature" })
    host.rects = {}
    ISInventoryItem.renderItemIcon(host, book, 0, 0, 1, 32, 32)
    ok = Assert.equal(#host.rects, 0, "non-equippables get no overlay bars") and ok
    return ok
end

return tests
