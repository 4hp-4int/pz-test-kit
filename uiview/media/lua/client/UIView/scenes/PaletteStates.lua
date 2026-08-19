--[[
    UIView — Scene: SaucePalette frontend states + driver
    =====================================================
    A RICH fixture + a thin input driver for full frontend testing of the real
    SaucePaletteUI. Drives the panel's own input hooks (the same entry points the
    game calls) so tests exercise real keyboard/mouse behaviour, and captures a
    gallery of notable states for visual refinement.

    Driver (operate on a built root):
      D.type(root, q)     set query + refilter
      D.up/down(root)     move selection (entry.onPressUp/onPressDown)
      D.enter(root)       activate selection (entry.onCommandEntered -> runSel)
      D.key(root, k)      a non-text key (Esc/F1/Tab/Ins) via entry.onOtherKey
      D.wheel(root, d)    scroll selection
      D.clickLocal(root, lx, ly)  mouse-down in panel-local coords
      D.closed            set true when the palette asked to close (Esc / run)
]]

require "UIView/UIMock"
UIView_setScreen(1280, 800)
require "palette/pal_ui"
local Theme = require "palette/pal_theme"   -- same instance pal_ui themes from
pcall(function() require "palette/pal_needs" end)
pcall(function() require "palette/pal_synonyms" end)   -- production always loads these

local SP = _G.SaucePalette

-- runSel() calls SaucePalette.close()/feedback()/invalidate(); stub them so the
-- real run path executes without a game. close() flips a flag tests can read.
local D = { closed = false, lastFeedback = nil }
SP.close = function() D.closed = true end
SP.feedback = function(_, text, good) D.lastFeedback = { text = text, good = good } end
SP.invalidate = function() end

-- In-memory pins (no file I/O) so star/Ins wiring is testable headlessly.
do
    local pinned = setmetatable({}, { __mode = "k" })
    SP.Pins = {
        isPinned = function(cmd) return pinned[cmd] == true end,
        toggle = function(cmd) pinned[cmd] = not pinned[cmd] or nil end,
    }
end

-- ---- fixture --------------------------------------------------------------
local function batchDetail(title, out)
    return function()
        return { title = title, rows = {
            { text = "Box of 9mm Rounds", tone = "consume", qty = "x1" },
            { text = out, tone = "make", qty = "x50" },
        }, footer = "[Shift] x5   [Ctrl] all" }
    end
end

local function richCommands()
    local noop = function() end
    local cmds = {}
    local function add(c)
        c.runnable = (c.runnable ~= false)
        c.run = c.run or noop
        cmds[#cmds + 1] = c
    end

    -- batchable craft (quantity / modifier path)
    add({ label = "Open Box of Bullets", source = "Box of 9mm Rounds", category = "craft",
        icon = "Item_HandgunAmmoBox", maxN = 50, runN = function(n) return n end,
        buildDetail = batchDetail("Open Box", "9mm Round") })
    add({ label = "Craft Crude Bandage", source = "Ripped Sheets", category = "craft", icon = "Item_Sheet" })

    -- build (barricade group via the 'barri' filter)
    add({ label = "Barricade Window", source = "Planks", category = "build", icon = "Item_Plank" })
    add({ label = "Barricade Door", source = "Sheet Metal", category = "build", icon = "Item_SheetMetal" })

    -- blocked crafts (greyed + reason tag) — runnable=false, blockReason set
    add({ label = "Forge Machete", source = "Metal Bar", category = "craft", icon = "Item_Machete",
        runnable = false, blockReason = "needs forge" })
    add({ label = "Read in the Dark", source = "Carpentry Vol.2", category = "read", icon = "Item_Book",
        runnable = false, blockReason = "needs light" })
    add({ label = "Saw Logs", source = "Log", category = "craft", icon = "Item_Logs",
        runnable = false, blockReason = "needs surface" })

    -- needs targets
    add({ label = "Bandage Wound", source = "Bandage", category = "med", icon = "Item_Bandage" })
    add({ label = "Drink Water", source = "Water Bottle", category = "drink", icon = "Item_WaterBottle_Full" })
    add({ label = "Eat Stew", source = "Pot of Stew", category = "eat", icon = "Item_Saucepan" })
    add({ label = "Smoke Cigarette", source = "Cigarettes", category = "use", icon = "Item_Cigarette" })

    -- duplicate verb -> collapses into "Equip Primary (3)" group
    add({ label = "Equip Primary", source = "Machete", category = "equip", icon = "Item_Machete" })
    add({ label = "Equip Primary", source = "Hammer", category = "equip", icon = "Item_Hammer" })
    add({ label = "Equip Primary", source = "Kitchen Knife", category = "equip", icon = "Item_KnifeChopping" })

    -- inspect / edit / open (de-shadowed verb categories)
    add({ label = "Inspect Leather Jacket", source = "Leather Jacket", category = "inspect", icon = "Item_JacketLeatherBlack" })
    add({ label = "Rename Duffel Bag", source = "Duffel Bag", category = "edit", icon = "Item_Duffelbag" })
    add({ label = "Open Canned Beans", source = "Canned Beans", category = "open", icon = "Item_Beans" })

    -- world verbs (harvested from nearby squares) — these float in zero-state
    add({ label = "Board Up Window", source = "Window", category = "world", kind = "world" })
    add({ label = "Open Wooden Door", source = "Door", category = "world", kind = "world" })
    add({ label = "Sleep", source = "Bed", category = "world", kind = "world" })

    -- vehicle verbs (DRIVE chip) — the palette unifies these too
    add({ label = "Start Engine", source = "Pickup Truck", category = "vehicle", icon = "Item_CarBattery" })
    add({ label = "Open Hood", source = "Pickup Truck", category = "vehicle" })

    -- long label (truncation)
    add({ label = "Disassemble Large Electronic Generator Housing Assembly",
        source = "Generator", category = "place", icon = "Item_Generator" })

    -- filler so result count exceeds MAX_ROWS (scroll)
    for i = 1, 10 do
        add({ label = "Place Furniture " .. i, source = "Crate", category = "place", icon = "Item_Crate" })
    end

    return cmds
end

-- bleeding moodle fixture (real boostFor ranks Bandage to the top, tag "bleeding")
local function setBleeding(on)
    if not (SP and SP.Needs) then return end
    SP.Needs.snapshot = on
        and function() return { cat = { world = 1500, med = 4200 }, lbl = { bandage = 4400 }, fx = {}, memo = {} } end
        or  function() return { cat = { world = 1500 }, lbl = {}, fx = {}, memo = {} } end
end

-- wounded fixture: the injury keywords pal_needs.scanInjuries would emit, so the
-- medical treatment rows rank up with the right "why" tags (fracture/embedded/...).
local function setWounded(on)
    if not (SP and SP.Needs) then return end
    if on then
        SP.Needs.snapshot = function()
            return { cat = { world = 1500, med = 1400 },
                     lbl = { splint = 2600, ["remove glass"] = 3000, stitch = 2800, disinfect = 2400 },
                     fx = {}, memo = {} }
        end
    else
        SP.Needs.snapshot = function() return { cat = { world = 1500 }, lbl = {}, fx = {}, memo = {} } end
    end
end

-- Medical treatment rows the way pal_medical emits them (per part, "med" chip,
-- runnable iff you hold the item). Four distinct injuries each surface their own
-- treatment + "why" tag (fracture/embedded/deep wound/infected); one row is
-- blocked to show the missing-item reason.
local function medicalCommands()
    return {
        { label = "Remove Glass - Right Hand", source = "Right Hand", category = "med", icon = "Item_Tweezers", runnable = true },
        { label = "Stitch - Left Forearm", source = "Left Forearm", category = "med", icon = "Item_SutureNeedle", runnable = true },
        { label = "Splint - Left Arm", source = "Left Arm", category = "med", icon = "Item_Splint", runnable = true },
        { label = "Disinfect - Right Foot", source = "Right Foot", category = "med", icon = "Item_Alcohol", runnable = true },
        { label = "Remove Bullet - Left Thigh", source = "Left Thigh", category = "med", icon = "Item_Tweezers",
          runnable = false, blockReason = "need tweezers" },
    }
end

local States = {}
States.D = D
-- Exported so composers (the browser embed) can merge this feature-dense set
-- with the bar scene's families.
States.richCommands = richCommands

-- Build a configured root. opts = { query, bleeding, browse, expandGroup, help,
-- commands (override the fixture list), theme (skin id: nil/"midnight"/"paper") }.
function States.build(opts)
    opts = opts or {}
    D.closed = false; D.lastFeedback = nil
    -- exactly one needs-fixture (they share SP.Needs.snapshot, so don't clobber)
    if opts.wounded then setWounded(true)
    elseif opts.bleeding then setBleeding(true)
    else setBleeding(false) end

    -- theme skin. SaucePaletteUI:new calls SP.Settings.apply() internally, which
    -- applies whatever the theme COMBO selects (and would clobber a direct applyTheme).
    -- So drive the real path: stub the combo to the wanted index (1 diner / 2 midnight
    -- / 3 paper). Always set, so a themed build never leaks into the next.
    if SP.Settings then
        local idx = (opts.theme == "midnight" and 2) or (opts.theme == "paper" and 3)
            or (opts.theme == "forge" and 4) or (opts.theme == "cartRadio" and 5) or 1
        SP.Settings._theme = { getValue = function() return idx end }
    end
    pcall(function() Theme.applyTheme(opts.theme) end)   -- also set now for any pre-:new read

    local root = SaucePaletteUI:new(0)
    root:initialise()
    root._ready = true
    -- pal_ui deliberately does NOT use the widget placeholder (it draws its own
    -- "What's the order?" in render(), gated on an empty box — see pal_ui ~270). The
    -- harness must match, or the mock's placeholder draws ON TOP of pal_ui's, garbling
    -- the bar. So leave entry.placeholder unset.
    root.entry._focused = true
    if opts.query and opts.query ~= "" then root.entry:setText(opts.query) end
    local cmds = opts.commands or richCommands()
    if opts.wounded then
        for _, c in ipairs(medicalCommands()) do cmds[#cmds + 1] = c end
    end
    -- pin a row before setAllCommands so refilter ranks + tags it as pinned
    if opts.pin then
        for _, c in ipairs(cmds) do if c.label == opts.pin then pcall(SP.Pins.toggle, c) end end
    end
    root:setAllCommands(cmds)

    if opts.browse then root.entry.onOtherKey(root.entry, Keyboard.KEY_TAB) end
    if opts.help then root.showHelp = true end
    if opts.expandGroup then
        -- select the Equip group and expand it.
        -- NB: this expansion does NOT survive the first rendered frame — the
        -- panel's prerender query poll refilters (see States.selectGroup), which
        -- rebuilds the groups and drops the flag. Fine for row-level assertions
        -- on an unrendered root; anything that CAPTURES must use
        -- States.settle + States.selectGroup instead.
        States.selectGroup(root)
    end
    return root
end

-- Render one throwaway frame so the panel's own first-frame work has happened.
-- SaucePaletteUI:_lastQuery starts nil (only enterPickMode and the poll itself
-- ever set it), so the first prerender always sees "" ~= nil, refilters, and
-- calls selectFirstSelectable() — wiping any selection/expansion set at build
-- time. The real game eats that same frame before the player can press a key,
-- so settling here is what a player actually sees, not a workaround.
function States.settle(root, w, h)
    local Render = require "UIView/Render"
    Render.capture(root, w or 1280, h or 800)
    return root
end

-- Select the first group row (pal_groups emits kind == "group" for a collapsed
-- family) and Enter it, which toggles the family open.
function States.selectGroup(root)
    for i, r in ipairs(root.rows) do
        if r.kind == "group" then root.sel = i; break end
    end
    root:runSel()
    return root
end

-- ---- input driver ---------------------------------------------------------
function D.type(root, q) root.entry:setText(q or ""); root:refilter() end
function D.up(root)   root.entry.onPressUp() end
function D.down(root) root.entry.onPressDown() end
function D.enter(root) root.entry.onCommandEntered() end
-- A focused PZ text box only ever receives Esc and Tab via onOtherKey (Core hardcodes
-- those two), plus Enter/nav and typed characters. Function keys and printable hotkeys
-- ("?" help, "/" pin) reach the box ONLY as typed characters — tests exercise those by
-- setText(...) + a rendered frame (the prerender query poll), not via D.key. So D.key
-- models just the real onOtherKey channel.
function D.key(root, k)
    root.entry.onOtherKey(root.entry, k)
end
function D.wheel(root, d) root:onMouseWheel(d) end
function D.clickLocal(root, lx, ly) return root:onMouseDown(lx, ly) end

-- ---- gallery of states for visual inspection ------------------------------
-- Returns { label, caption, frame } beats (reusing the storyboard shape).
function States.gallery()
    local Render = require "UIView/Render"
    local W, H = 1280, 800
    local out = {}
    -- `act` (optional) runs against a SETTLED root — after the panel has eaten
    -- its first rendered frame — so state it sets survives into the capture.
    local function shot(label, caption, opts, act)
        local root = States.build(opts)
        if act then act(States.settle(root, W, H)) end
        out[#out + 1] = { label = label, caption = caption, frame = Render.capture(root, W, H) }
    end

    shot("zero",     "Zero-state (suggested)", {})
    shot("filtered", "Typed 'ba' (filter)",    { query = "ba" })
    shot("group",    "Group expanded",          {}, States.selectGroup)
    shot("browse",   "Browse (by category)",    { browse = true })
    shot("bleeding", "Needs-aware (bleeding)",  { bleeding = true })
    shot("wounded",  "Medical (injury-aware)",  { wounded = true })
    shot("pinned",   "Pinned favorite (star)",  { pin = "Eat Stew" })
    shot("blocked",  "Blocked recipes ('e')",   { query = "e" })
    shot("batch",    "Quantity prefix",         { query = "5 open box" })
    shot("nomatch",  "No matches",              { query = "zzzzzz" })
    shot("help",     "Help overlay (F1)",       { help = true })
    return out
end

return States
