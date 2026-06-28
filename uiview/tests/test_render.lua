--[[
    UIView — render + drive tests
    =============================
    Proves the foundation end to end on PZ's real Kahlua VM:
      1. A panel renders headlessly into a display list (no game running).
      2. The display list is emitted as JSON for the browser viewer.
      3. The panel is DRIVABLE — injected clicks hit the right element and
         mutate state, asserted offline.
]]

local Assert    = PZTestKit.Assert
local Recorder  = require "UIView/Recorder"
local Render    = require "UIView/Render"
local Input     = require "UIView/Input"
local Demo      = require "UIView/scenes/DemoTooltip"

-- ── Emit the scene JSON once at load (host wrapper extracts it) ──────────────
do
    local root = Demo.build()
    Render.emit(root, 420, 280, "demo")
end

-- ── helpers ─────────────────────────────────────────────────────────────────
local function findText(substr)
    for _, op in ipairs(Recorder.ops) do
        if op.op == "text" and tostring(op.str):find(substr, 1, true) then
            return op
        end
    end
    return nil
end

local function countOps(kind)
    local n = 0
    for _, op in ipairs(Recorder.ops) do
        if op.op == kind then n = n + 1 end
    end
    return n
end

local tests = {}

tests["renders_a_nonempty_display_list"] = function()
    local root = Demo.build()
    Render.frame(root, 420, 280)
    return Assert.greater(#Recorder.ops, 0, "display list has ops")
end

tests["weapon_name_text_is_painted"] = function()
    local root = Demo.build()
    Render.frame(root, 420, 280)
    return Assert.notNil(findText("Vorpal Machete"), "weapon name text op present")
end

tests["progress_bar_fill_matches_kills"] = function()
    local root = Demo.build()
    Render.frame(root, 420, 280)
    -- panel inner width = 300 - 24 = 276; frac = 247/300
    local expectedFill = 276 * (247 / 300)
    local found = nil
    for _, op in ipairs(Recorder.ops) do
        if op.op == "rect" and math.abs(op.w - expectedFill) < 0.5
            and math.abs(op.h - 12) < 0.5 then
            found = op
        end
    end
    return Assert.notNil(found, "fill rect width == kills/nextAt fraction")
end

tests["hit_test_resolves_topmost_button"] = function()
    local root = Demo.build()
    local btn = root._buttons.inspect
    -- center of the Inspect button in screen coords
    local sx = btn:getAbsoluteX() + btn.width / 2
    local sy = btn:getAbsoluteY() + btn.height / 2
    local hit = Input.hitTest(root, sx, sy)
    return Assert.equal(hit and hit.Type, "ISButton", "topmost hit is the button, not the panel")
end

tests["click_drives_button_state"] = function()
    local root = Demo.build()
    local btn = root._buttons.inspect
    local sx = btn:getAbsoluteX() + btn.width / 2
    local sy = btn:getAbsoluteY() + btn.height / 2
    Input.click(root, sx, sy)
    return Assert.equal(btn.title, "Inspected!", "click handler mutated button title")
end

tests["click_outside_button_does_not_fire"] = function()
    local root = Demo.build()
    local btn = root._buttons.inspect
    Input.click(root, root:getAbsoluteX() + 5, root:getAbsoluteY() + 5) -- panel title area
    return Assert.equal(btn.title, "Inspect", "title unchanged when click misses button")
end

return tests
