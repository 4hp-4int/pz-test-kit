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

local SaucePalette = {}

-- A representative command set: a mix of categories so chips/colors show, a
-- duplicate verb ("Equip Primary") that collapses into a group, and a craft
-- with a detail pane (ingredients/output).
local function fixtureCommands()
    local noop = function() end
    local cmds = {}
    local function add(c) c.runnable = (c.runnable ~= false); c.run = c.run or noop; cmds[#cmds + 1] = c end

    add({ label = "Craft Crude Bandage", source = "Ripped Sheets", category = "craft",
        icon = "Item_Bandage",
        buildDetail = function()
            return {
                title = "Crude Bandage",
                rows = {
                    { text = "Ripped Sheets", tone = "consume", qty = "x1" },
                    { text = "Suturing Needle", tone = "tool", qty = "" },
                    { text = "Crude Bandage", tone = "make", qty = "x1" },
                },
                footer = "Hand craft - ready",
            }
        end })
    add({ label = "Build Wooden Wall", source = "Planks", category = "build",
        icon = "Item_Plank",
        buildDetail = function()
            return { title = "Wooden Wall", rows = {
                { text = "Planks", tone = "consume", qty = "x4" },
                { text = "Nails", tone = "consume", qty = "x4" },
                { text = "Hammer", tone = "tool", qty = "" },
                { text = "Wooden Wall", tone = "make", qty = "x1" },
            }, footer = "Place after build" }
        end })
    add({ label = "Read Carpentry Vol.2", source = "The Carpenter's Bible", category = "read",
        icon = "Item_Book" })

    -- duplicate verb -> collapses into "Equip Primary (3)" group
    add({ label = "Equip Primary", source = "Machete", category = "equip", icon = "Item_Machete" })
    add({ label = "Equip Primary", source = "Hammer", category = "equip", icon = "Item_Hammer" })
    add({ label = "Equip Primary", source = "Kitchen Knife", category = "equip", icon = "Item_KitchenKnife" })

    add({ label = "Eat Apple", source = "Apple", category = "eat", icon = "Item_Apple" })
    add({ label = "Drink Water", source = "Water Bottle", category = "drink", icon = "Item_WaterBottle_Full" })
    add({ label = "Bandage Wound", source = "Bandage", category = "med", icon = "Item_Bandage" })
    add({ label = "Smoke Cigarette", source = "Cigarettes", category = "use", icon = "Item_Cigarette" })
    add({ label = "Place Generator", source = "Generator", category = "place", icon = "Item_Generator" })
    add({ label = "Open Door", source = "Wooden Door", category = "open" })

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
    root:setAllCommands(fixtureCommands())  -- runs refilter -> buildGroups -> rows
    return root
end

return SaucePalette
