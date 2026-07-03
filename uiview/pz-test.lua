-- UIView harness config. Preloads the mock ISUI layer so scenes/tests can
-- derive ISPanel/ISButton/ISLabel without each requiring it, and pulls in
-- sibling mods whose REAL panels we want to render headlessly.
return {
    preload = {
        "UIView/UIMock",
    },

    -- Index these mods' media/lua into the require path so scenes can load
    -- their actual UI files (e.g. require "palette/pal_ui").
    dependencies = {
        "../../sauce-shortorder",   -- the order box (pal_*)
        "../../sauce-invrender",    -- the inventory rendering (sir_*)
        "../../PZ-TooltipLib",
        "../../VorpallySauced",
        "../../SauceTooltips",      -- theme accents (cross-mod colour coherence)
    },

    -- Load the REAL vanilla inventory window Lua so the render is like-for-like
    -- with the in-game window (title bar, frame, chrome). These execute against
    -- UIMock's recording ISPanel base, so their draws are captured. Loaded in
    -- dependency order; their internal require "ISUI/*" calls are stubbed below
    -- (the globals are set as each file executes).
    vanilla_requires = {
        -- The real inventory-window chrome. (We don't load the 113KB
        -- ISInventoryPane — SIR replaces its renderdetails anyway; we feed the page
        -- our SIR pane as its inventoryPane.)
        "client/ISUI/ISInventoryPage",
    },

    -- Core-PZ widgets the real panels require but the harness mocks as globals.
    -- (Stubbed = require returns nil; the global class comes from UIMock or from a
    -- vanilla_requires file that already executed.)
    stub_requires = {
        "ISUI/ISTextEntryBox",
        "ISUI/ISRichTextPanel",
        "ISUI/ISScrollingListBox",
        "ISUI/ISInventoryItem",
        -- vanilla inventory-window deps: bases come from UIMock, the rest we don't
        -- instantiate (we drive the pane + chrome directly), so nil is fine.
        "ISUI/ISPanel", "ISUI/ISButton", "ISUI/ISInventoryPane", "ISUI/ISResizeWidget",
        "ISUI/ISMouseDrag", "ISUI/ISLayoutManager", "ISUI/ISScrollBar",
        "ISUI/InventoryWindow/ISInventoryWindowContainerControls",
        "ISUI/LootWindow/ISLootWindowContainerControls",
        "Definitions/ContainerButtonIcons", "defines",
        -- TooltipLib's dedicated-client MP path; we render the SP path, so the
        -- network module isn't needed (its symbols are only hit when isClient()).
        "TooltipLib/MPClient",
    },
}
