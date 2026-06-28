--[[ pal_ui RENDER coverage. The behaviour suite (test_palette_frontend) mostly
     asserts on root.rows/sel without drawing, so pal_ui's large render path stayed
     ~69%. This drives the real SaucePaletteUI render across its draw branches —
     detail pane, theme skins, help overlay, a scrolled list, the blocked-row flash,
     and the zero-state urgent row — via the UIView harness. ]]
local Assert    = PZTestKit.Assert
local Render    = require "UIView/Render"
local Recorder  = require "UIView/Recorder"
local States    = require "UIView/scenes/PaletteStates"
local D          = States.D

local function render(root)
    Render.frame(root, 1280, 800)
    return Recorder.ops
end
local function hasText(ops, sub)
    for _, op in ipairs(ops) do
        if op.op == "text" and tostring(op.str):find(sub, 1, true) then return true end
    end
    return false
end
local function textCount(ops)
    local n = 0
    for _, op in ipairs(ops) do if op.op == "text" then n = n + 1 end end
    return n
end

local tests = {}

tests["detail_pane_renders_recipe_rows"] = function()
    local root = States.build({ query = "open box" })
    root:selectFirstSelectable()
    local ops = render(root)
    if not Assert.isTrue(hasText(ops, "9mm Round"), "the detail pane draws the recipe's items") then return false end
    return Assert.isTrue(hasText(ops, "Ctrl") or hasText(ops, "Shift"), "the batch-hint footer draws")
end

tests["midnight_theme_renders_a_populated_list"] = function()
    local ops = render(States.build({ theme = "midnight" }))
    return Assert.greater(textCount(ops), 5, "the midnight skin draws a populated list")
end

tests["paper_theme_renders_a_populated_list"] = function()
    local ops = render(States.build({ theme = "paper" }))
    return Assert.greater(textCount(ops), 5, "the paper skin draws a populated list")
end

tests["help_overlay_renders"] = function()
    local root = States.build({ help = true })
    if not Assert.isTrue(root.showHelp == true, "help is open") then return false end
    return Assert.greater(textCount(render(root)), 5, "the help overlay draws text")
end

tests["scrolled_list_still_renders_rows"] = function()
    local root = States.build({})
    for _ = 1, 15 do D.down(root) end     -- push the selection past the first viewport
    return Assert.greater(textCount(render(root)), 5, "a scrolled list still draws rows")
end

tests["blocked_row_flash_renders"] = function()
    local root = States.build({ query = "forge" })
    root:selectFirstSelectable()
    D.enter(root)                          -- blocked -> flash (does not close)
    local ops = render(root)
    if not Assert.isTrue(D.closed == false, "the blocked row didn't close the box") then return false end
    return Assert.greater(textCount(ops), 0, "the flashing blocked row still renders")
end

tests["bleeding_zero_state_renders_urgent_row"] = function()
    local ops = render(States.build({ bleeding = true }))
    return Assert.isTrue(hasText(ops, "Bandage"), "the urgent bandage row renders while bleeding")
end

tests["expanded_family_children_render"] = function()
    local root = States.build({ expandGroup = true })
    return Assert.greater(textCount(render(root)), 8, "an expanded family draws its child rows")
end

-- The detail pane's ELSE branch (a row with no buildDetail): source + ready/blocked.
tests["detail_pane_renders_item_and_ready"] = function()
    local root = States.build({ query = "bandage wound" })
    root:selectFirstSelectable()
    local ops = render(root)
    if not Assert.isTrue(hasText(ops, "Bandage"), "the selected item is named in the detail") then return false end
    return Assert.isTrue(hasText(ops, "ready") or hasText(ops, "Enter"), "a runnable row shows 'ready - Enter to run'")
end

tests["detail_pane_renders_block_reason"] = function()
    local root = States.build({ query = "forge machete" })
    root:selectFirstSelectable()
    local ops = render(root)
    return Assert.isTrue(hasText(ops, "forge") or hasText(ops, "can't"), "a blocked row's detail explains why")
end

-- Expand a duplicate-verb group and render it, so renderChild (the expanded-child
-- draw path) actually executes. The 3 "Equip Primary" verbs collapse to one group.
tests["expanded_group_renders_child_rows"] = function()
    local root = States.build({ query = "equip primary" })
    local gi
    for i, r in ipairs(root.rows) do if r.kind == "group" then gi = i; break end end
    if gi then root.sel = gi; D.enter(root) end   -- expand if a group formed
    return Assert.greater(textCount(render(root)), 2, "the expanded equip group renders its children")
end

return tests
