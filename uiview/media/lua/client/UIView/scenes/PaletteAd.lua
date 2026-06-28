--[[
    UIView — Scene: SaucePalette AD storyboard
    ==========================================
    Drives the REAL SaucePaletteUI through a scripted run (the 90s-ad demo) and
    captures one frame per beat. Every frame is produced by the palette's own
    refilter/buildGroups/render, so the typing-filters-the-list, needs-aware
    ranking and batch-count beats are authentic, not faked.

    Uses ONLY phosphor icons that exist on disk, so the viewer/player resolve
    them to real pixels (see media/ui/phosphor/).

    Beats (Render.emitStoryboard payload):
      open -> b/ba/bar/barr/barri (rows filter to Barricade) -> run
      -> bleeding (Bandage floats to top with a "bleeding" tag, zero-state)
      -> batch ("5 open box" -> quantity parsed)
]]

require "UIView/UIMock"
UIView_setScreen(1280, 800)

require "palette/pal_ui"   -- global SaucePaletteUI + _G.SaucePalette (= SP)

-- Real needs ranking: load the actual boostFor/snapshot, then override snapshot
-- with a fixtured moodle state (no live player headless). The ranking + "why"
-- tag are the library's own code; we only supply the moodle input.
pcall(function() require "palette/pal_needs" end)

local SP = _G.SaucePalette

local Ad = {}

-- Icons are REAL PZ inventory textures referenced by their pack subtexture name
-- ("Item_<Icon>"); build_view.py extracts them straight from the game's .pack
-- files. This is what the palette draws in-game (item:getTexture()).
-- Command set tuned for the ad narrative. Two "Barricade ..." rows so typing
-- "barri" visibly narrows; a med row for the bleeding beat; an ammo craft for
-- the batch beat; a spread of categories for chip colour.
local function fixtureCommands()
    local noop = function() end
    local cmds = {}
    local function add(c)
        c.runnable = (c.runnable ~= false)
        c.run = c.run or noop
        cmds[#cmds + 1] = c
    end

    add({ label = "Barricade Window", source = "Planks",  category = "build", icon = "Item_Plank",
        buildDetail = function()
            return { title = "Barricade Window", rows = {
                { text = "Planks", tone = "consume", qty = "x4" },
                { text = "Nails",  tone = "consume", qty = "x4" },
                { text = "Hammer", tone = "tool", qty = "" },
            }, footer = "Hand craft - ready" }
        end })
    add({ label = "Barricade Door", source = "Sheet Metal", category = "build", icon = "Item_SheetMetal" })

    add({ label = "Bandage Wound", source = "Bandage", category = "med",  icon = "Item_Bandage" })
    add({ label = "Open Box of Bullets", source = "Box of 9mm Rounds", category = "craft", icon = "Item_HandgunAmmoBox",
        batch = true,
        buildDetail = function()
            return { title = "Open Box", rows = {
                { text = "Box of 9mm Rounds", tone = "consume", qty = "x1" },
                { text = "9mm Round", tone = "make", qty = "x50" },
            }, footer = "[Shift] x5   [Ctrl] all" }
        end })

    add({ label = "Drink Water",     source = "Water Bottle", category = "drink", icon = "Item_WaterBottle_Full" })
    add({ label = "Eat Stew",        source = "Pot of Stew",  category = "eat",   icon = "Item_Saucepan" })
    add({ label = "Equip Machete",   source = "Machete",      category = "equip", icon = "Item_Machete" })
    add({ label = "Equip Hammer",    source = "Hammer",       category = "equip", icon = "Item_Hammer" })
    add({ label = "Read First Aid",  source = "First Aid Vol.1", category = "read", icon = "Item_Book" })
    add({ label = "Place Generator", source = "Generator",    category = "place", icon = "Item_Generator" })

    return cmds
end

-- A fixtured bleeding snapshot: boostFor reads snap.cat / snap.lbl / snap.fx.
-- The "bandage" label keyword maps (REASON_LABEL) to the "bleeding" tag, and the
-- big boost floats the med row to the top in zero-state — exactly what a real
-- Bleeding moodle would produce.
local function installBleeding()
    if not (SP and SP.Needs) then return end
    SP.Needs.snapshot = function()
        return { cat = { world = 1500, med = 4200 }, lbl = { bandage = 4400 }, fx = {}, memo = {} }
    end
end
local function clearNeeds()
    if SP and SP.Needs then SP.Needs.snapshot = function()
        return { cat = { world = 1500 }, lbl = {}, fx = {}, memo = {} }
    end end
end

-- Build a palette root for one beat. opts = { query=?, bleeding=? }.
function Ad.build(opts)
    opts = opts or {}
    if opts.bleeding then installBleeding() else clearNeeds() end

    local root = SaucePaletteUI:new(0)
    root:initialise()
    root._ready = true
    root.entry.placeholder = "Search actions..."
    root.entry._focused = true
    if opts.query and opts.query ~= "" then root.entry:setText(opts.query) end
    root:setAllCommands(fixtureCommands())
    return root
end

-- The scripted storyboard: { label, query, caption, durationMs, frame }.
function Ad.storyboard()
    local W, H = 1280, 800
    local beats = {}
    local function beat(meta, opts)
        local root = Ad.build(opts)
        meta.frame = require("UIView/Render").capture(root, W, H)
        beats[#beats + 1] = meta
    end

    -- Pacing: `quick` marks the per-keystroke typing beats (snappy hard cuts, no
    -- settle); other beats get an ease-in + a readable hold so captions land.
    -- durationMs is wall-clock the player holds that frame.
    beat({ label = "open",  caption = "ONE KEY.",                durationMs = 1600 }, {})
    beat({ label = "b",     caption = "TYPE THE VERB", quick = true, durationMs = 230 }, { query = "b" })
    beat({ label = "ba",    caption = "TYPE THE VERB", quick = true, durationMs = 230 }, { query = "ba" })
    beat({ label = "bar",   caption = "TYPE THE VERB", quick = true, durationMs = 230 }, { query = "bar" })
    beat({ label = "barr",  caption = "TYPE THE VERB", quick = true, durationMs = 230 }, { query = "barr" })
    beat({ label = "barri", caption = "IT FINDS THE VERB",        durationMs = 2200, kind = "run" }, { query = "barri" })
    beat({ label = "bleeding", caption = "IT KNOWS WHAT YOU NEED", durationMs = 2600, bleeding = true }, { bleeding = true })
    beat({ label = "batch", caption = "BATCH CRAFT. ONE KEY.",    durationMs = 2600 }, { query = "5 open box" })
    beat({ label = "close", caption = "SAY THE THING.",          durationMs = 2400 }, {})

    return beats
end

return Ad
