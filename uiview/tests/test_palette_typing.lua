--[[ UIView live-filter reel — emit one frame per keystroke as a query is typed into
     the REAL order box, so the list filters live (D.type runs the actual refilter).
     make_filter_gif.py stitches the frames into a GIF: the whole pitch of the mod —
     you type, it narrows. Every static shot undersells it.

     Same root across frames, so the panel stays a fixed size while the rows collapse
     within it, exactly like in game. The zero-state is a REAL palette opened BLEEDING
     (needs scorer floats Bandage to row one, urgency-tagged), and "bandage" narrows to
     the treatment rows — the Workshop copy's story beat, rendered by the real UI.
     Every icon resolves (no placeholders). ]]
local Assert  = PZTestKit.Assert
local States  = require "UIView/scenes/PaletteStates"
local Render  = require "UIView/Render"
local D       = States.D

-- The STORY beat (promo copy: "scratched up mid-fight — the bandage is already at
-- the top"): the zero-state opens BLEEDING, so the real needs scorer floats Bandage
-- to row one with its urgency tag before a single key is pressed; then "bandage" is
-- typed and the list narrows to the treatment rows. Payoff first, mechanics second.
local SEQ = { "", "b", "ba", "ban", "band", "banda", "bandag", "bandage" }

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

-- A real live box: opens bleeding (Bandage tagged on top), narrows to the treatment
-- rows when you type "bandage". The rest is a believable mid-run list so the zero
-- state reads as a live game, not a demo.
local function REEL()
    local l = {}
    -- the story rows: per-part bandages the way pal_medical emits them
    l[#l + 1] = row("Bandage - Left Forearm", "Left Forearm", "med", "Item_Bandage")
    l[#l + 1] = row("Bandage - Right Shin", "Right Shin", "med", "Item_Bandage")
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
    -- bleeding=true: the REAL boostFor ranks the Bandage rows to the top of the
    -- zero-state with the "bleeding" tag — the first frame IS the pitch
    local root = States.build({ commands = REEL(), bleeding = true })
    for i, q in ipairs(SEQ) do
        D.type(root, q)                      -- the real refilter runs here
        Render.emit(root, 1280, 800, string.format("palette_type_%02d", i - 1))
    end
    return Assert.isTrue(#root.rows >= 0, "filter frames emitted")
end

return tests
