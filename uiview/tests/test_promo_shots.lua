--[[ UIView promo shots — emit the named order-box states the Workshop slides/headers
     capture. Render.emit prints @@UIVIEW_BEGIN:<name>@@…@@UIVIEW_END:<name>@@; then
       ./uiview.sh <name>            -> out/view.html
       python capture_promo.py <name>   -> shots/<name>.png
     drops the PNG the matching sso-slide / sso-header points at. These aren't
     assertions — they exist to be photographed.

     Each shot is a REAL palette (world-dominated, family groups with verb
     breadcrumbs, pinned favourites, blocked rows, food portions) tuned to its
     message — the same character as the hero "palette" scene. Every icon name
     resolves from the game's texture packs, so there are no placeholder slots;
     a world row with no item icon just wears its category chip. ]]

local Assert  = PZTestKit.Assert
local States  = require "UIView/scenes/PaletteStates"
local Render  = require "UIView/Render"

local function row(label, source, category, icon)
    return { label = label, source = source, category = category, kind = category,
             icon = icon, runnable = true, run = function() end }
end

local function blocked(label, source, category, reason, icon)
    return { label = label, source = source, category = category, kind = category,
             icon = icon, runnable = false, blockReason = reason, run = function() end }
end

-- Append a noun-head family (verb children that collapse under one head with a
-- right-side verb breadcrumb). members = { {label, order, default, icon, runnable, blockReason}, ... }
local function family(list, key, head, cat, flavor, members)
    for _, m in ipairs(members) do
        list[#list + 1] = {
            label = m.label, source = m.source, category = cat, kind = cat, icon = m.icon,
            runnable = (m.runnable ~= false), blockReason = m.blockReason, run = function() end,
            familyKey = key, familyLabel = head, familyCategory = cat,
            familyFlavor = flavor, familyDefault = m.default, familyOrder = m.order,
        }
    end
end

-- The bar around you: the world/loot/grab rows shared by the indoor shots, so each
-- one reads like a busy live box rather than a curated list.
local function barRows(list)
    family(list, "barseat", "Leather Bar Seating", "world", "Rest, Sleep, Pick Up, Disassemble", {
        { label = "Rest", order = 1, default = true, icon = "Item_Moveable_object" }, { label = "Sleep", order = 2 },
        { label = "Pick Up", order = 3 }, { label = "Disassemble", order = 4 },
    })
    list[#list + 1] = row("Sit on ground", "nearby", "world", nil)
    family(list, "lootfloor", "Loot Floor", "loot", nil, {
        { label = "Beer (Beer Can)", order = 1, default = true, icon = "Item_BeerCan" },
        { label = "Whiskey", order = 2 }, { label = "Vodka", order = 3 },
        { label = "Bourbon", order = 4 }, { label = "Red Wine", order = 5 },
        { label = "Shot Glass", order = 6 }, { label = "Bar Rag", order = 7 }, { label = "Bottle Cap", order = 8 },
    })
    list[#list + 1] = row("Pick Up Beer (Beer Can)", "Beer (Beer Can)", "grab", "Item_BeerCan")
    list[#list + 1] = row("Pick Up Oak Table (1/2)", "Oak Table (1/2)", "grab", "Item_Moveable_object")
end

-- header_back / slide_buried — "Best stuff's in the back": the Build 42 work hidden
-- on the interact key. A survivor working a yard, so the box is full of farm /
-- woodcutting / mining / foraging / cleaning verbs you'd never find in a right-click.
local function BACK()
    local l = {}
    family(l, "tomato", "Tomato Plant", "farm", "Water, Fertilize, Harvest, Clear", {
        { label = "Water",            order = 1, default = true, icon = "Item_WateringCan" },
        { label = "Fertilize",        order = 2 },
        { label = "Harvest",          order = 3 },
        { label = "Clear Dead Plant", order = 4 },
    })
    l[#l + 1] = row("Plow Furrow", "Dirt", "farm", "Item_Shovel")
    family(l, "oaktree", "Oak Tree", "chop", "Chop Down, Saw Logs, Cut Branches", {
        { label = "Chop Down",   order = 1, default = true, icon = "Item_Axe" },
        { label = "Saw Logs",    order = 2, icon = "Item_Handsaw" },
        { label = "Cut Branches", order = 3 },
    })
    l[#l + 1] = row("Mine Flint", "Rock Outcrop", "mine", "Item_PickAxe")
    l[#l + 1] = row("Forage Here", "Wild Food", "forage", "Item_MushroomGeneric1")
    l[#l + 1] = row("Scrub Blood", "Floor", "clean", "Item_Bleach")
    l[#l + 1] = row("Scythe Grass", "Long Grass", "chop", nil)
    l[#l + 1] = row("Siphon Gas", "Pickup Truck", "vehicle", "Item_Petrol")
    l[#l + 1] = blocked("Dig Up Stump", "Tree Stump", "chop", "need a shovel", nil)
    l[#l + 1] = row("Splint - Left Arm", "Left Arm", "med", "Item_Splint")
    return l
end

-- header_reads / slide_mods — "I don't check the handwriting": vanilla and modded in
-- one list. The wrench is a VorpallySauced affix piece, the leotard is Frockin's;
-- distinct verbs so the modded names stay visible (flat, not collapsed into a group),
-- with a few world/bar rows underneath for the live-box density.
local function MODMIX()
    local l = {
        row("Open Wooden Door", "Door", "world", nil),
        row("Bandage Wound", "Bandage", "med", "Item_Bandage"),
        row("Equip Primary", "Tireless Pipe Wrench of Preservation (Bloody)", "equip", "Item_PipeWrench"),
        row("Holster", "Colt Python Revolver", "attach", "Item_RevolverLong"),
        row("Wear", "Cotton Leotard (Sleeves Medium Cut)", "equip", nil),
        row("Drink Beer", "Beer (Beer Can)", "drink", "Item_BeerCan"),
        row("Read", "Electrical I: \"Basic Electronics\"", "read", "Item_Book6"),
    }
    barRows(l)
    return l
end

-- header_knows / slide_urgent — "It knows what you need": the bleeding bandage jumps
-- the line of a real, busy box (the bleeding moodle floats the med row to the top).
local function BLEED()
    local l = {
        row("Bandage Wound", "Bandage", "med", "Item_Bandage"),
        row("Take Pills", "Painkillers", "med", "Item_Pills"),
        row("Drink Beer", "Beer (Beer Can)", "drink", "Item_BeerCan"),
        row("Read", "Electrical I: \"Basic Electronics\"", "read", "Item_Book6"),
        row("Destroy", nil, "world", "Item_Sledgehammer2"),
    }
    barRows(l)
    return l
end

-- slide_station + the skin chips — "Set up your station": one list across the three
-- skins (diner / midnight / paper). Pinned Window family on top so the family detail
-- pane shows, plus a spread of categories so each skin's colours read.
local function SKINS()
    local l = {}
    family(l, "window", "Window", "world", "Barricade, Remove Glass", {
        { label = "Barricade (Metal Bars)", order = 1, default = true, icon = "Item_Moveable_window" },
        { label = "Barricade (Planks)", order = 2, icon = "Item_Plank" },
        { label = "Barricade (Metal Sheet)", order = 3 },
        { label = "Remove Broken Glass", order = 4, runnable = false, blockReason = "hands empty" },
    })
    l[#l + 1] = row("Take Pills", "Painkillers", "med", "Item_Pills")
    l[#l + 1] = row("Drink Beer", "Beer (Beer Can)", "drink", "Item_BeerCan")
    family(l, "lootfloor", "Loot Floor", "loot", nil, {
        { label = "Beer (Beer Can)", order = 1, default = true, icon = "Item_BeerCan" },
        { label = "Whiskey", order = 2 }, { label = "Vodka", order = 3 }, { label = "Shot Glass", order = 4 },
    })
    l[#l + 1] = row("Read", "Electrical I: \"Basic Electronics\"", "read", "Item_Book6")
    l[#l + 1] = row("Pick Up Beer (Beer Can)", "Beer (Beer Can)", "grab", "Item_BeerCan")
    return l
end

-- Build a shot the way the live box looks: collapse any auto-expanded/pinned family
-- to its head and select the top row, so a pinned family shows its option pane
-- ("Default: X / N options") instead of fanning open. Skip when a query is set.
local function emit(name, opts)
    local root = States.build(opts)
    for _, g in ipairs(root.groups or {}) do g.expanded = false end
    if root.rebuildRows then root:rebuildRows() end
    root.sel = 1
    root._lastQuery = ""
    Render.emit(root, 1280, 800, name)
    return root
end

local tests = {}

tests["emit_promo_shots"] = function()
    -- pin a family head so the top row reads "<head>  pinned (N) >" with its detail pane
    local back = emit("palette_back", { commands = BACK(), pin = "Water" })

    -- pin the VPS wrench so the modded payload tops the list (and lands in the header's
    -- zoomed crop) instead of being buried under the rank-0 world rows.
    emit("palette_modmix", { commands = MODMIX(), pin = "Equip Primary" })
    emit("palette_bleed",  { commands = BLEED(), bleeding = true })

    emit("palette_diner",    { commands = SKINS(), pin = "Barricade (Metal Bars)" })
    emit("palette_midnight", { commands = SKINS(), pin = "Barricade (Metal Bars)", theme = "midnight" })
    emit("palette_paper",    { commands = SKINS(), pin = "Barricade (Metal Bars)", theme = "paper" })
    -- crossover skins (VorpallySauced / SaucedCarts)
    emit("palette_forge",    { commands = SKINS(), pin = "Barricade (Metal Bars)", theme = "forge" })
    emit("palette_cartradio",{ commands = SKINS(), pin = "Barricade (Metal Bars)", theme = "cartRadio" })

    States.build({})   -- rebuild on the default skin so the theme doesn't leak onward

    return Assert.isTrue(#back.rows > 0, "the buried-actions scene built rows to photograph")
end

return tests
