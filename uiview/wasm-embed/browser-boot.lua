-- Browser boot: builds the scene and defines UIView_tick(eventLine) -> frame
-- JSON. Mirrors the server's ServeBoot, but returns the frame instead of
-- printing it (the JS side calls this directly through Fengari).

require "UIView/UIMock"
UIView_setScreen(1280, 800)

-- The embed redraws only on input events, so a mid-flight row-cascade frame
-- would freeze half-slid. Kill motion: every captured frame is the settled one.
local T = require "palette/pal_theme"
if T then T.motionEnabled = false end

local Render = require "UIView/Render"
local Input  = require "UIView/Input"
local scene  = require "UIView/scenes/SaucePalette"

local root, W, H

local function rebuild()
    root = scene.build()
    W = (root.x or 0) + (root.width or 0) + 40
    H = (root.y or 0) + (root.height or 0) + 40
end
rebuild()

local function num(s) return s and tonumber(s) or nil end

-- keyboard routed through the panel's real input hooks (same as ServeBoot)
local function dispatchKey(name)
    local e = root.entry
    if not e then return end
    if name == "up" and e.onPressUp then e.onPressUp()
    elseif name == "down" and e.onPressDown then e.onPressDown()
    elseif name == "enter" and e.onCommandEntered then e.onCommandEntered()
    elseif name == "tab" and e.onOtherKey then e.onOtherKey(e, Keyboard.KEY_TAB)
    elseif name == "f1" and e.onOtherKey then e.onOtherKey(e, Keyboard.KEY_F1)
    elseif name == "esc" and e.onOtherKey then e.onOtherKey(e, Keyboard.KEY_ESCAPE) end
end

local function dispatch(ev)
    local cmd = ev:match("^(%S+)") or "render"
    if cmd == "text" then
        local s = ev:match("^text%s?(.*)$") or ""
        if root.entry and root.entry.setText then
            root.entry:setText(s); root.entry._focused = true
        end
    elseif cmd == "key" then
        dispatchKey(ev:match("^key%s+(%S+)") or "")
    elseif cmd == "reset" then
        rebuild()
    elseif cmd == "click" or cmd == "down" or cmd == "up" or cmd == "move" then
        local x, y = ev:match("(%-?%d+%.?%d*)%s+(%-?%d+%.?%d*)")
        x, y = num(x), num(y)
        if x and y then
            if cmd == "click" then Input.click(root, x, y)
            elseif cmd == "down" then Input.down(root, x, y)
            elseif cmd == "up" then Input.up(root, x, y)
            else Input.move(root, x, y) end
        end
    elseif cmd == "wheel" then
        local x, y, d = ev:match("(%-?%d+%.?%d*)%s+(%-?%d+%.?%d*)%s+(%-?%d+%.?%d*)")
        if x and y and d then Input.wheel(root, num(x), num(y), num(d)) end
    end
end

function UIView_tick(ev)
    pcall(dispatch, ev or "render")
    return Render.frame(root, W, H)   -- canonical JSON string
end

return true
