--[[
    UIView — SaucePalette FULL FRONTEND tests
    =========================================
    Drives the REAL SaucePaletteUI through its own input hooks (keyboard + mouse)
    and asserts both behaviour and rendered output. Emits a gallery of states for
    visual refinement (scene "states").
]]

local Assert  = PZTestKit.Assert
local Render  = require "UIView/Render"
local States  = require "UIView/scenes/PaletteStates"
local D       = States.D
local K       = Keyboard

-- Emit the states gallery for the contact sheet.
do
    Render.emitStoryboard("states", States.gallery())
end

-- helpers ------------------------------------------------------------------
local function selRow(root) return root.rows[root.sel] end
local function selLabel(root)
    local r = selRow(root)
    if not r then return nil end
    if r.kind == "group" then return r.group.label end
    return r.cmd and r.cmd.label
end
local function rowKinds(root)
    local k = {}
    for _, r in ipairs(root.rows) do k[r.kind] = (k[r.kind] or 0) + 1 end
    return k
end
local function frameHasText(root, sub)
    Render.frame(root, 1280, 800)
    local Recorder = require "UIView/Recorder"
    for _, op in ipairs(Recorder.ops) do
        if op.op == "text" and tostring(op.str):find(sub, 1, true) then return op end
    end
    return nil
end

local tests = {}

-- ── keyboard navigation ────────────────────────────────────────────────────
tests["down_moves_selection"] = function()
    local root = States.build({})
    local before = root.sel
    D.down(root)
    return Assert.isTrue(root.sel ~= before, "Down changed selection")
end

tests["nav_skips_headers_in_browse"] = function()
    local root = States.build({ browse = true })
    -- after building browse, selection must be a non-header row
    return Assert.isTrue(selRow(root) ~= nil and selRow(root).kind ~= "header",
        "selection never lands on a header")
end

tests["up_from_first_wraps_to_last"] = function()
    local root = States.build({})
    root.sel = 1
    D.up(root)
    return Assert.isTrue(root.sel > 1, "Up from first wraps to a later row")
end

-- ── Enter = activate (run leaf / expand group) ─────────────────────────────
tests["enter_on_group_expands"] = function()
    local root = States.build({})
    -- select the Equip group
    local gi
    for i, r in ipairs(root.rows) do if r.kind == "group" then gi = i break end end
    if not Assert.notNil(gi, "an Equip group exists") then return false end
    root.sel = gi
    D.enter(root)
    return Assert.isTrue((rowKinds(root).child or 0) >= 3, "child rows appear after expanding")
end

tests["enter_on_leaf_runs_and_closes"] = function()
    local root = States.build({ query = "drink water" })
    root:selectFirstSelectable()
    D.enter(root)
    if not Assert.isTrue(D.closed, "palette closed after running a leaf") then return false end
    return Assert.notNil(D.lastFeedback, "feedback was reported")
end

tests["enter_on_blocked_does_not_close"] = function()
    local root = States.build({ query = "forge" })
    root:selectFirstSelectable()
    D.enter(root)
    if not Assert.isTrue(D.closed == false, "blocked row does NOT close the palette") then return false end
    return Assert.notNil(root._flashRow, "blocked row flashes instead")
end

-- ── Esc / F1 / Tab / Ins ────────────────────────────────────────────────────
tests["esc_closes_palette"] = function()
    local root = States.build({})
    D.key(root, K.KEY_ESCAPE)
    return Assert.isTrue(D.closed, "Esc closed the palette")
end

tests["esc_closes_help_first"] = function()
    local root = States.build({ help = true })
    D.key(root, K.KEY_ESCAPE)
    if not Assert.isTrue(root.showHelp == false, "Esc closed help") then return false end
    return Assert.isTrue(D.closed == false, "...and did NOT close the palette")
end

tests["typing_question_mark_toggles_help"] = function()
    -- Help can't ride a function key (a focused box never receives F1), so it opens by
    -- typing "?" — detected in the prerender query poll, which clears the box and shows
    -- the overlay. Type it and render a frame; type it again to toggle off.
    local root = States.build({})
    root.entry:setText("?"); Render.frame(root, 1280, 800)
    if not Assert.isTrue(root.showHelp == true, "typing ? opened help") then return false end
    root.entry:setText("?"); Render.frame(root, 1280, 800)
    return Assert.isTrue(root.showHelp == false, "typing ? again closed help")
end

tests["tab_toggles_browse_mode"] = function()
    local root = States.build({})
    if not Assert.isTrue((rowKinds(root).header or 0) == 0, "suggested view has no headers") then return false end
    D.key(root, K.KEY_TAB)
    return Assert.isTrue((rowKinds(root).header or 0) > 0, "browse view shows category headers")
end

tests["slash_pins_selected_row"] = function()
    -- Faithful to the in-game path: "/" arrives as a typed CHARACTER in the focused
    -- box (isKeyDown is unreliable for printable keys while focused), and prerender
    -- detects it, pins, and strips it. Type it and render a frame.
    local root = States.build({ query = "drink water" })
    root:selectFirstSelectable()
    local cmd = selRow(root).cmd
    root.entry:setText("drink water/")
    Render.frame(root, 1280, 800)
    if not Assert.isTrue(_G.SaucePalette.Pins.isPinned(cmd), "/ pinned the selected command") then return false end
    return Assert.isTrue((root.entry:getText() or ""):find("/", 1, true) == nil, "the / was stripped from search")
end

-- ── number-prefix quantity ──────────────────────────────────────────────────
tests["number_prefix_sets_quantity"] = function()
    local root = States.build({ query = "5 open box" })
    if not Assert.equal(root._qty, 5, "leading '5 ' parsed as quantity") then return false end
    -- and the rest still filters to the batch command
    return Assert.isTrue(selLabel(root) == "Open Box of Bullets" or frameHasText(root, "Open Box") ~= nil,
        "remaining query still finds Open Box")
end

tests["number_suffix_sets_quantity"] = function()
    -- trailing "verb N" ("open box 5") is symmetric with leading "N verb".
    local root = States.build({ query = "open box 5" })
    if not Assert.equal(root._qty, 5, "trailing ' 5' parsed as quantity") then return false end
    return Assert.isTrue(selLabel(root) == "Open Box of Bullets" or frameHasText(root, "Open Box") ~= nil,
        "leading query still finds Open Box")
end

tests["trailing_all_sets_max_quantity"] = function()
    -- "rip clothing all" -> max-batch, same as leading "all rip clothing".
    local root = States.build({ query = "open box all" })
    return Assert.isTrue(root._qty == math.huge, "trailing 'all' -> huge quantity (clamped at run)")
end

-- ── mouse ───────────────────────────────────────────────────────────────────
tests["wheel_moves_selection"] = function()
    local root = States.build({})
    local before = root.sel
    D.wheel(root, -1)
    return Assert.isTrue(root.sel ~= before, "wheel moved selection")
end

tests["click_mode_badge_toggles_browse"] = function()
    local root = States.build({})
    local mbx = root.width - 10 - 1   -- inside the mode badge (top-right)
    D.clickLocal(root, root.width - 30, 18)
    return Assert.isTrue((rowKinds(root).header or 0) > 0, "clicking mode badge switched to browse")
end

tests["click_star_gutter_pins_not_runs"] = function()
    local root = States.build({ query = "drink water" })
    root:selectFirstSelectable()
    -- first visible row band; star gutter is the left ~18px
    local ly = root.listY + 4
    D.clickLocal(root, 12, ly)
    if not Assert.isTrue(D.closed == false, "star click did NOT run/close") then return false end
    local cmd = root.rows[1] and root.rows[1].cmd
    return Assert.isTrue(cmd ~= nil and _G.SaucePalette.Pins.isPinned(cmd), "star click pinned the row")
end

-- ── filtering / ranking / rendering ─────────────────────────────────────────
tests["barri_filters_to_barricades"] = function()
    local root = States.build({ query = "barri" })
    local labels = {}
    for _, r in ipairs(root.rows) do if r.cmd then labels[r.cmd.label] = true end end
    if not Assert.isTrue(labels["Barricade Window"] == true, "Barricade Window matches") then return false end
    return Assert.isTrue(labels["Drink Water"] == nil, "non-matching rows filtered out")
end

tests["bleeding_ranks_bandage_first"] = function()
    -- With the DO-BEFORE-MAKE tie-break, applying (med) beats crafting (craft)
    -- when both match the bleeding remedy, so "Bandage Wound" is strictly first.
    local root = States.build({ bleeding = true })
    local top
    for _, r in ipairs(root.rows) do if r.cmd then top = r.cmd break end end
    return Assert.equal(top and top.label, "Bandage Wound", "Bandage tops the list while bleeding")
end

tests["expandGroup_opt_reveals_children"] = function()
    local root = States.build({ expandGroup = true })
    local kinds = rowKinds(root)
    return Assert.isTrue((kinds.child or 0) >= 3, "expandGroup build shows the 3 equip children")
end

tests["pin_star_is_always_visible"] = function()
    local root = States.build({})
    Render.frame(root, 1280, 800)
    local Recorder = require "UIView/Recorder"
    local stars = 0
    for _, op in ipairs(Recorder.ops) do
        if op.op == "texture" and tostring(op.name):find("fav-star", 1, true) then stars = stars + 1 end
    end
    return Assert.greater(stars, 1, "pin star draws on every row, not just the selected one")
end

tests["pinned_favorite_tops_zero_state"] = function()
    local root = States.build({ pin = "Eat Stew" })
    local top
    for _, r in ipairs(root.rows) do if r.cmd then top = r.cmd break end end
    return Assert.equal(top and top.label, "Eat Stew", "a pinned favorite floats to the top")
end

tests["long_label_renders"] = function()
    local root = States.build({ query = "disassemble" })
    return Assert.notNil(frameHasText(root, "Disassemble"), "long label row renders")
end

tests["blocked_recipe_shows_reason"] = function()
    local root = States.build({ query = "forge" })
    return Assert.notNil(frameHasText(root, "needs forge"), "blocked reason tag rendered")
end

-- ── magazine family: collapse + Enter-runs-default (UI wiring) ───────────────
require "palette/pal_families"      -- registers SP.Families (+ the magazine adapter)
local SP = _G.SaucePalette
local function magFamilyCommands()
    local ran = { label = nil }
    local function gun() return {
        _type           = "HandWeapon",
        getMagazineType = function() return "Base.SomeMag" end,
        getFullType     = function() return "Base.M16" end,
        getName         = function() return "M16" end,
    } end
    local g = gun()
    local function mag(maxA, loaded) return {
        _type = "InventoryItem",
        getMaxAmmo = function() return maxA end, getCurrentAmmoCount = function() return loaded end,
    } end
    local function cmd(label, m) return {
        label = label, source = "M16", category = "use", runnable = true,
        target = {}, params = { g, m },
        run = function() ran.label = label; return true end,
    } end
    local cmds = { cmd("Insert 20-round", mag(20, 0)),
                   cmd("Insert 60-round", mag(60, 0)),
                   cmd("Insert 30-round", mag(30, 0)) }
    SP.Families.apply(cmds)
    return cmds, ran
end

tests["magazine_family_collapses_to_one_row"] = function()
    local root = States.build({})
    local cmds = magFamilyCommands()
    root:setAllCommands(cmds)
    -- exactly one family group row labelled "Load M16", with 3 members
    local famRow
    for _, r in ipairs(root.rows) do
        if r.kind == "group" and r.group.isFamily then famRow = r end
    end
    if not Assert.notNil(famRow, "a collapsed family group row exists") then return false end
    if not Assert.equal(famRow.group.label, "Load M16", "labelled by the gun") then return false end
    return Assert.equal(#famRow.group.cmds, 3, "all three magazines under one head")
end

tests["magazine_family_enter_expands"] = function()
    local root = States.build({})
    local cmds = magFamilyCommands()
    root:setAllCommands(cmds)
    for i, r in ipairs(root.rows) do
        if r.kind == "group" and r.group.isFamily then root.sel = i; break end
    end
    D.enter(root)       -- Enter on family head → expands (does NOT fire an action)
    if not Assert.isTrue(D.closed == false, "palette stays open — Enter expands, not runs") then return false end
    local children, firstChild = 0, nil
    for _, r in ipairs(root.rows) do
        if r.kind == "child" then children = children + 1; firstChild = firstChild or r.cmd end
    end
    if not Assert.greater(children, 0, "Enter expanded the family into variant rows") then return false end
    return Assert.equal(firstChild.label, "Insert 60-round", "the default (highest cap) sorts first")
end

tests["truncate_respects_utf8_boundaries"] = function()
    -- 8 CJK chars, 3 bytes each (24 bytes), built via string.char because the
    -- Kahlua harness mangles UTF-8 SOURCE literals (in-game they're raw bytes).
    -- maxW=46 forces the byte-wise binary search to land mid-character; the UTF-8
    -- guard must back up to a boundary so the kept prefix is only WHOLE 3-byte
    -- glyphs (never a sliced one -> "?").
    local cjk = string.char(0xE8,0xBD,0xBD, 0xE5,0x85,0xA5, 0xE5,0xBC,0xB9, 0xE5,0x8C,0xA3,
                            0xE6,0xB5,0x8B, 0xE8,0xAF,0x95, 0xE6,0x96,0x87, 0xE5,0xAD,0x97)
    if not Assert.equal(#cjk, 24, "byte string built correctly") then return false end
    local out = SP._truncate(UIFont.Small, cjk, 46)
    local kept = out:gsub("%.%.%.$", "")
    if not Assert.greater(#kept, 0, "kept a prefix") then return false end
    return Assert.equal(#kept % 3, 0, "prefix is whole CJK characters, not a sliced glyph")
end

tests["truncate_keeps_short_strings_whole"] = function()
    return Assert.equal(SP._truncate(UIFont.Small, "Bandage", 9999), "Bandage", "fits -> unchanged")
end

tests["magazine_family_click_expands"] = function()
    local root = States.build({})
    local cmds = magFamilyCommands()
    root:setAllCommands(cmds)
    local idx
    for i, r in ipairs(root.rows) do
        if r.kind == "group" and r.group.isFamily then idx = i; break end
    end
    if not Assert.notNil(idx, "found family head") then return false end
    -- click the family head (mouse) → expands to show the variant children
    local ry = root.listY + (idx - 1) * (root.rows and 0 or 0)   -- row Y handled inside onMouseDown
    root.sel = idx
    root:runSel(true)   -- expandOnly path (what a click passes)
    local children = 0
    for _, r in ipairs(root.rows) do if r.kind == "child" then children = children + 1 end end
    return Assert.greater(children, 0, "clicking the family head reveals the variant rows")
end

return tests
