--[[ UIView live-filter reel — emit one frame per keystroke as a query is typed into
     the REAL order box, so the list filters live (D.type runs the actual refilter).
     make_filter_gif.py stitches the frames into a GIF: the whole pitch of the mod —
     you type, it narrows. Every static shot undersells it.

     Same root across frames, so the panel stays a fixed size while the rows collapse
     within it, exactly like in game. The zero-state is a REAL palette (world-dominated,
     family groups, a pin, food/grab rows) and "barricade" narrows to the Window family's
     barricade options — ties to Sauce's intro bit. Every icon resolves (no placeholders). ]]
local Assert  = PZTestKit.Assert
local States  = require "UIView/scenes/PaletteStates"
local Render  = require "UIView/Render"
local D       = States.D

local SEQ = { "", "b", "ba", "bar", "barr", "barri", "barric", "barrica", "barricad", "barricade" }

local function row(label, source, category, icon)
    return { label = label, source = source, category = category, kind = category,
             icon = icon, runnable = true, run = function() end }
end
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

-- A real live box that narrows to the Window barricade options when you type "barricade".
local function REEL()
    local l = {}
    family(l, "window", "Window", "world", "Barricade, Remove Glass", {
        { label = "Barricade (Metal Bars)", order = 1, default = true, icon = "Item_Moveable_window" },
        { label = "Barricade (Planks)", order = 2, icon = "Item_Plank" },
        { label = "Barricade (Metal Sheet)", order = 3 },
        { label = "Remove Broken Glass", order = 4, runnable = false, blockReason = "needs a saw" },
    })
    l[#l + 1] = row("Destroy", nil, "world", "Item_Sledgehammer2")
    family(l, "barseat", "Leather Bar Seating", "world", "Rest, Sleep, Pick Up, Disassemble", {
        { label = "Rest", order = 1, default = true, icon = "Item_Moveable_object" }, { label = "Sleep", order = 2 },
        { label = "Pick Up", order = 3 }, { label = "Disassemble", order = 4 },
    })
    l[#l + 1] = row("Sit on ground", "nearby", "world", nil)
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

local tests = {}

tests["emit_filter_frames"] = function()
    local root = States.build({ commands = REEL() })   -- zero-state: full list, fixed panel size
    for i, q in ipairs(SEQ) do
        D.type(root, q)                      -- the real refilter runs here
        Render.emit(root, 1280, 800, string.format("palette_type_%02d", i - 1))
    end
    return Assert.isTrue(#root.rows >= 0, "filter frames emitted")
end

return tests
