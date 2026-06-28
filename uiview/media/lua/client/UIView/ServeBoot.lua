--[[
    UIView — Serve bootstrap (resident live-drive)
    ==============================================
    Loaded once by the harness's --serve mode. Builds the requested scene and
    defines the global UIView_serve_tick(), which the Java loop calls once per
    input command (read from stdin). Each tick dispatches the command into the
    LIVE panel via Input, re-renders, and prints one "@@FRAME@@<json>" line that
    the Node bridge forwards to the browser.

    This is the real Kahlua VM — the same one the tests and snapshots use — kept
    resident, so clicking the browser drives the actual panel code.

    Command grammar (one per line):
      click <x> <y> | down <x> <y> | up <x> <y> | move <x> <y>
      wheel <x> <y> <delta> | text <string> | reset | render
    Coords are in frame space (= screen space; frame origin is 0,0).
]]

require "UIView/UIMock"
local Render = require "UIView/Render"
local Input  = require "UIView/Input"

local sceneName = _uiview_scene or "SaucePalette"
local scene = require("UIView/scenes/" .. sceneName)

local root, W, H

local function rebuild()
    root = scene.build()
    -- Frame covers the panel with a small margin. Scenes may override via
    -- scene.frame = { w, h } (e.g. to render on a full screen for centering).
    if scene.frame then
        W, H = scene.frame.w, scene.frame.h
    else
        W = (root.x or 0) + (root.width or 0) + 40
        H = (root.y or 0) + (root.height or 0) + 40
    end
end

local function emit()
    -- Render.frame returns the canonical JSON string (no sentinels of its own).
    print("@@FRAME@@" .. Render.frame(root, W, H))
end

rebuild()

local function num(s) return s and tonumber(s) or nil end

-- Keyboard nav routed through the panel's REAL input hooks. In game a focused
-- ISTextEntryBox eats arrows/Enter/Esc and calls these itself; we call the same
-- callbacks so navigation behaves identically (moveSel, runSel, Tab/F1/Esc via
-- onOtherKey). Panel-specific (guarded on root.entry); generic scenes ignore.
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
            root.entry:setText(s)
            root.entry._focused = true
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
    -- cmd == "render" falls through to a plain re-emit.
end

function UIView_serve_tick()
    -- never let a dispatch error skip the frame — emit is the protocol contract
    pcall(dispatch, _uiview_event or "render")
    emit()
end

return true
