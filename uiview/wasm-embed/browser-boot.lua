-- Browser boot: builds the scene and defines UIView_tick(eventLine) -> frame
-- JSON. Mirrors the server's ServeBoot, but returns the frame instead of
-- printing it (the JS side calls this directly through Fengari).
--
-- Boots on the PaletteStates scene so the embed can show the whole feature
-- set: needs-aware ranking (bleeding / wounded fixtures), the five skins via
-- the real Settings theme path, quantity prefixes, blocked reasons, families,
-- pins, help. The command list merges the bar scene's families (Window /
-- Loot Floor / bar seating, pinned favourites) with the feature-dense
-- richCommands set (batchable craft, blocked crafts, equip group, vehicle,
-- scroll filler).

require "UIView/UIMock"
UIView_setScreen(1280, 800)

-- The embed redraws only on input events, so a mid-flight row-cascade frame
-- would freeze half-slid. Kill motion: every captured frame is the settled one.
-- (The zero clock in browser-harness snaps the row glide the same way.)
local T = require "palette/pal_theme"
if T then T.motionEnabled = false end

local Render = require "UIView/Render"
local Input  = require "UIView/Input"
local Bar    = require "UIView/scenes/SaucePalette"      -- bar-scene fixture
local States = require "UIView/scenes/PaletteStates"     -- driver + rich fixture

local function mergedCommands()
    local cmds = Bar.fixtureCommands()
    for _, c in ipairs(States.richCommands()) do cmds[#cmds + 1] = c end
    return cmds
end

-- Session state the JS controls surface. Theme/needs survive resets; reset
-- clears the query and rebuilds on the same skin and body state.
local S = { theme = nil, bleeding = false, wounded = false }

local root, W, H

local function rebuild()
    root = States.build({
        commands = mergedCommands(),
        theme    = S.theme,
        bleeding = S.bleeding,
        wounded  = S.wounded,
        pin      = "Barricade (Metal Bars)",
    })
    -- Collapse the auto-expanded pinned family and select the head, like the
    -- live box at rest (same shaping the promo shots do).
    for _, g in ipairs(root.groups or {}) do g.expanded = false end
    if root.rebuildRows then root:rebuildRows() end
    root.sel = 1
    root._lastQuery = ""
    W = 1280
    H = 800
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
    elseif cmd == "theme" then
        local id = ev:match("^theme%s+(%S+)")
        S.theme = (id ~= "diner") and id or nil
        rebuild()
    elseif cmd == "bleeding" then
        S.bleeding = ev:match("on") ~= nil
        if S.bleeding then S.wounded = false end
        rebuild()
    elseif cmd == "wounded" then
        S.wounded = ev:match("on") ~= nil
        if S.wounded then S.bleeding = false end
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
        -- d may carry several coalesced browser wheel steps (a tick is ~100ms
        -- under Fengari, so the JS side batches a burst into one event). The
        -- panel's onMouseWheel only reads the sign, so replay |d| single steps.
        local x, y, d = ev:match("(%-?%d+%.?%d*)%s+(%-?%d+%.?%d*)%s+(%-?%d+%.?%d*)")
        if x and y and d then
            x, y, d = num(x), num(y), num(d)
            local sign = d > 0 and 1 or -1
            for _ = 1, math.min(math.abs(d), 20) do
                Input.wheel(root, x, y, sign)
            end
        end
    end
end

function UIView_tick(ev)
    pcall(dispatch, ev or "render")
    return Render.frame(root, W, H)   -- canonical JSON string
end

return true
