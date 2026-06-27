--[[ UIView promo shots — emit the named order-box states the Workshop cards capture.
     Render.emit prints @@UIVIEW_BEGIN:<name>@@…@@UIVIEW_END:<name>@@; then
       ./uiview.sh <name>            -> out/view.html
       python shoot.py out/view.html shots/<name>.png
     drops the PNG the matching sso-card points at. These aren't assertions — they
     exist to be photographed. (palette_zero / the loop frames are captured the same way
     off the existing "palette" scene.) ]]

local Assert  = PZTestKit.Assert
local States  = require "UIView/scenes/PaletteStates"
local Render  = require "UIView/Render"

local function row(label, source, category, icon)
    return { label = label, source = source, category = category, kind = category,
             icon = icon, runnable = true, run = function() end }
end

-- Card 03 "Best stuff's in the back" — the Build 42 work hidden on the interact key.
local BURIED = {
    row("Plow",             "Tilled Dirt",   "farm",    "Item_Shovel"),
    row("Water Tomato",     "Tomato Plant",  "farm",    "Item_WateringCan"),
    row("Saw Logs",         "Tree",          "chop",    "Item_Handsaw"),
    row("Mine Flint",       "Rock Outcrop",  "mine",    "Item_PickAxe"),
    row("Forage Mushroom",  "Wild Food",     "forage",  "Item_MushroomGeneric1"),
    row("Scrub Blood",      "Floor",         "clean",   "Item_Bleach"),
    row("Siphon Gas",       "Pickup Truck",  "vehicle", "Item_Petrol"),
    row("Splint - Left Arm","Left Arm",      "med",     "Item_Splint"),
}

-- Card 02 "I don't check the handwriting" — vanilla and modded verbs, one list.
local MODMIX = {
    row("Open Wooden Door", "Door",            "world",   nil),
    row("Bandage Wound",    "Bandage",         "med",     "Item_Bandage"),
    row("Field Strip",      "Hunting Rifle",   "use",     "Item_HuntingRifle"),
    row("Brew Coffee",      "Coffee Maker",    "use",     "Item_Coffee"),
    row("Reload Magazine",  "M9 Pistol",       "use",     "Item_Pistol"),
    row("Take All",         "Fridge",          "loot",    "Item_Fridge"),
    row("Start Engine",     "Pickup Truck",    "vehicle", "Item_CarBattery1"),
    row("Read Carpentry",   "Carpentry Vol.2", "read",    "Item_Book"),
}

-- Card 05 "Set up your station" — one list, three skins (diner / midnight / paper).
local SKINDEMO = {
    row("Bandage Wound",   "Bandage",      "med",     "Item_Bandage"),
    row("Barricade Window","Planks",       "build",   "Item_Plank"),
    row("Loot Fridge",     "Fridge",       "loot",    "Item_Fridge"),
    row("Saw Logs",        "Tree",         "chop",    "Item_Saw"),
    row("Start Engine",    "Pickup Truck", "vehicle", "Item_CarBattery1"),
}

local tests = {}

tests["emit_promo_shots"] = function()
    local back = States.build({ commands = BURIED })
    Render.emit(back, 1280, 800, "palette_back")

    Render.emit(States.build({ commands = MODMIX }),  1280, 800, "palette_modmix")
    Render.emit(States.build({ bleeding = true }),    1280, 800, "palette_bleed")

    Render.emit(States.build({ commands = SKINDEMO }),                      1280, 800, "palette_diner")
    Render.emit(States.build({ commands = SKINDEMO, theme = "midnight" }),  1280, 800, "palette_midnight")
    Render.emit(States.build({ commands = SKINDEMO, theme = "paper" }),     1280, 800, "palette_paper")

    States.build({})   -- rebuild on the default skin so the theme doesn't leak onward

    return Assert.isTrue(#back.rows > 0, "the buried-actions scene built rows to photograph")
end

return tests
