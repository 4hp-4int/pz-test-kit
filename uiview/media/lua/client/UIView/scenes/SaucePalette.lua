--[[
    UIView — Scene: the REAL SaucePalette panel
    ===========================================
    Loads sauce-invrender's actual palette/pal_ui.lua (via the `dependencies`
    index in pz-test.lua) and renders the live SaucePaletteUI headlessly with a
    fixture command set. No game, no SIR runtime — just the panel's own render
    code painting into the display list.

    Returns build(query) -> root element (query defaults to "" = zero-state).
]]

require "UIView/UIMock"
UIView_setScreen(1280, 800)          -- size BEFORE :new() so layout fits the frame

require "palette/pal_ui"             -- defines global SaucePaletteUI + _G.SaucePalette

-- pal_main (the hotkey/lifecycle module) isn't loaded in the harness, so its
-- _G.SaucePalette.close() is absent. Enter on a runnable row and Esc both call
-- it — stub a no-op so keyboard activation runs the command without trying to
-- tear down a UIManager we don't have (keeps the panel up for live preview).
if _G.SaucePalette and not _G.SaucePalette.close then
    _G.SaucePalette.close = function() end
end

-- pal_ui's drawStar calls SP.Pins.isPinned unguarded, and pal_filter floats a
-- pinned row (tag "pinned") to the top in zero-state. pal_pins (the file-backed
-- impl) is loaded by pal_main, which the harness doesn't pull — so provide an
-- in-memory Pins so the capture shows real pinned rows + stars.
if _G.SaucePalette then
    local pinned = setmetatable({}, { __mode = "k" })
    _G.SaucePalette.Pins = {
        isPinned = function(cmd) return pinned[cmd] == true end,
        toggle   = function(cmd) pinned[cmd] = not pinned[cmd] or nil end,
    }
end

local SaucePalette = {}

-- A REAL order box, the way it opens mid-game: dominated by the WORLD verbs
-- harvested off the nearby squares (a window, the bar furniture, the floor), with
-- a couple of pinned favourites floated to the top, family groups carrying their
-- verb breadcrumb, one blocked row, food portions, and the loot/grab rows for the
-- bar around you. Modelled on a live capture standing in a looted bar.
-- Every icon name is one that resolves from the game's texture packs -- no
-- placeholder slots; world rows that have no item icon just wear their category chip.
local function fixtureCommands()
    local noop = function() end
    local cmds = {}
    local function add(c)
        c.runnable = (c.runnable ~= false)
        c.run = c.run or noop
        c.kind = c.kind or c.category
        cmds[#cmds + 1] = c
        return c
    end

    -- A family: a noun head with verb children. members = list of
    -- { label, order, default, runnable, blockReason, icon }. The grouping engine
    -- collapses them under `head` and shows the verb list as the row breadcrumb.
    local function family(key, head, cat, flavor, members)
        for _, m in ipairs(members) do
            add({
                label = m.label, source = m.source, category = cat, kind = cat, icon = m.icon,
                runnable = m.runnable, blockReason = m.blockReason,
                familyKey = key, familyLabel = head, familyCategory = cat,
                familyFlavor = flavor, familyDefault = m.default, familyOrder = m.order,
            })
        end
    end

    -- WINDOW -- pinned. Barricade options + a blocked "remove glass". Selected at
    -- the top, so the detail pane reads "Default: Barricade (Metal Bars) / 4 options".
    family("window", "Window", "world", "Barricade, Remove Glass", {
        { label = "Barricade (Metal Bars)",  order = 1, default = true, icon = "Item_Moveable_window" },
        { label = "Barricade (Planks)",       order = 2, icon = "Item_Plank" },
        { label = "Barricade (Metal Sheet)",  order = 3 },
        { label = "Remove Broken Glass",      order = 4, runnable = false, blockReason = "needs a saw" },
    })

    -- DESTROY -- pinned single.
    add({ label = "Destroy", category = "world", icon = "Item_Sledgehammer2" })

    -- The rest of the nearby-square verbs.
    family("foraging", "Foraging", "forage", "Enable, Window", {
        { label = "Enable", order = 1, default = true },
        { label = "Search This Window", order = 2 },
    })
    add({ label = "Sit on ground", source = "nearby", category = "world" })
    family("barseat", "Leather Bar Seating", "world", "Rest, Sleep, Pick Up, Disassemble", {
        { label = "Rest",         order = 1, default = true, icon = "Item_Moveable_object" },
        { label = "Sleep",        order = 2 },
        { label = "Pick Up",      order = 3 },
        { label = "Disassemble",  order = 4 },
    })
    add({ label = "Smash Window", source = "Window", category = "world", icon = "Item_Moveable_window" })
    add({ label = "Pick Up - Grey Diagonal Tiles", category = "world", runnable = false, blockReason = "need Crowbar", icon = "Item_Moveable_floortile" })

    -- Body / consumables.
    add({ label = "Take Pills", source = "Painkillers", category = "med", icon = "Item_Pills" })
    family("granola", "Granola Bar", "eat", "All, 1/2, 1/4", {
        { label = "Eat All", order = 1, default = true, icon = "Item_GranolaBar" },
        { label = "Eat 1/2", order = 2, icon = "Item_GranolaBar" },
        { label = "Eat 1/4", order = 3, icon = "Item_GranolaBar" },
    })
    add({ label = "Eat Gum", source = "Gum", category = "eat", icon = "Item_Gum" })

    -- The bar around you -- loot the floor, grab the loose stuff.
    family("lootfloor", "Loot Floor", "loot", nil, {
        { label = "Beer (Beer Can)", order = 1, default = true, icon = "Item_BeerCan" },
        { label = "Whiskey",   order = 2 },
        { label = "Vodka",     order = 3 },
        { label = "Bourbon",   order = 4 },
        { label = "Red Wine",  order = 5 },
        { label = "Shot Glass", order = 6 },
        { label = "Bar Rag",   order = 7 },
        { label = "Bottle Cap", order = 8 },
    })
    add({ label = "Pick Up Beer (Beer Can)", source = "Beer (Beer Can)", category = "grab", icon = "Item_BeerCan" })
    add({ label = "Pick Up Oak Table (1/2)", source = "Oak Table (1/2)", category = "grab", icon = "Item_Moveable_object" })

    return cmds
end

function SaucePalette.build(query)
    local root = SaucePaletteUI:new(0)
    root:initialise()                      -- builds the search box child
    root._ready = true                     -- skip focusSearch's engine-focus dance
    if query and query ~= "" then
        root.entry:setText(query)
    end
    root.entry.placeholder = "What's the order?"
    root.entry._focused = true
    local cmds = fixtureCommands()
    -- Pin the two favourites BEFORE setAllCommands so refilter tags them "pinned"
    -- and floats them to the top (pal_filter scores a pinned row at 4000 in zero-state).
    if _G.SaucePalette and _G.SaucePalette.Pins then
        for _, c in ipairs(cmds) do
            if c.label == "Barricade (Metal Bars)" or c.label == "Destroy" then
                _G.SaucePalette.Pins.toggle(c)
            end
        end
    end
    root:setAllCommands(cmds)  -- runs refilter -> buildGroups -> rows
    -- Zero-state only: buildGroups auto-expands the top pinned group; collapse
    -- everything and select the head so the capture matches the live box -- a
    -- collapsed "Window (4) >" with the family options in the detail pane
    -- ("Default: Barricade (Metal Bars) / 4 options"). Skip for query builds (tests).
    if not (query and query ~= "") then
        for _, g in ipairs(root.groups or {}) do g.expanded = false end
        if root.rebuildRows then root:rebuildRows() end
        root.sel = 1
        -- The render walk's prerender re-filters when the box text differs from
        -- _lastQuery (nil after setAllCommands), which would rebuild groups and re-expand.
        -- Pin _lastQuery to "" so the zero-state poll is a no-op and the collapse holds.
        root._lastQuery = ""
    end
    return root
end

return SaucePalette
