--[[
    UIView — Frame driver
    =====================
    Walks an element tree the way PZ's UIElement does each frame:
        prerender(self)  → render(children, in order)  → render(self)
    so backgrounds land under children and foreground (render) lands on top.

    Produces the Recorder display list + an element tree snapshot (geometry,
    type, id) so the viewer can outline elements and the input layer can
    hit-test. Call Render.frame(root, width, height) → returns the JSON string.
]]

local Recorder = require "UIView/Recorder"

local Render = {}

local function safe(el, method)
    local fn = el[method]
    if type(fn) ~= "function" then return end
    local ok, err = pcall(fn, el)
    if not ok and _pz_verbose then
        -- A stubbed PZ element's update/render erroring during the headless walk is
        -- expected (caught here; the snapshot continues). Quiet unless PZTEST_VERBOSE.
        print("[UIView] " .. tostring(el.Type or "?") .. ":" .. method ..
            "() error: " .. tostring(err))
    end
end

local function walk(el)
    if el == nil then return end
    if el.isVisible and el:isVisible() == false then return end
    safe(el, "update")
    safe(el, "prerender")
    local kids = el.childrenInOrder or {}
    for i = 1, #kids do walk(kids[i]) end
    safe(el, "render")
end

-- Snapshot the element tree as nested geometry boxes for the viewer overlay.
local function snapshot(el)
    if el == nil then return nil end
    local node = {
        id = el._uid,
        type = el.Type or "?",
        x = el.getAbsoluteX and el:getAbsoluteX() or el.x or 0,
        y = el.getAbsoluteY and el:getAbsoluteY() or el.y or 0,
        w = el.width or 0,
        h = el.height or 0,
        visible = (el.isVisible == nil) or (el:isVisible() ~= false),
        children = {},
    }
    local kids = el.childrenInOrder or {}
    for i = 1, #kids do
        node.children[#node.children + 1] = snapshot(kids[i])
    end
    return node
end

--- Capture a tree to a frame TABLE (ops + geometry tree), not JSON. Each call
--- resets the recorder, so the returned `ops` reference is a fresh list that
--- stays valid across later captures (the next reset swaps in a new table).
function Render.capture(root, width, height)
    Recorder.reset(width or (root.width + (root.x or 0)), height or (root.height + (root.y or 0)))
    walk(root)
    return {
        width = Recorder.frame.width,
        height = Recorder.frame.height,
        ops = Recorder.ops,
        tree = snapshot(root),
    }
end

--- Render a tree to a display-list frame and return the JSON string.
function Render.frame(root, width, height)
    local frame = Render.capture(root, width, height)
    Recorder.frame.tree = frame.tree
    return Recorder.toJSON()
end

--- Emit a STORYBOARD: an ordered list of beats, each a captured frame plus the
--- timing/caption metadata the player needs. The whole thing is one JSON object
--- ({ frames = [...] }) between named sentinels — the player loads it and drives
--- seek(t) over the beats. Beat shape (frame is a Render.capture table):
---   { label, query, caption, durationMs, kind?, typeFrom?, frame }
function Render.emitStoryboard(name, frames)
    local json = Recorder.encode({ frames = frames })
    print("@@UIVIEW_BEGIN:" .. (name or "ad") .. "@@")
    print(json)
    print("@@UIVIEW_END:" .. (name or "ad") .. "@@")
    return json
end

--- Print the frame JSON between named sentinels for the host wrapper to
--- extract. `name` lets multiple scenes coexist in one harness run; the
--- wrapper selects which block to pull.
function Render.emit(root, width, height, name)
    name = name or "scene"
    local json = Render.frame(root, width, height)
    print("@@UIVIEW_BEGIN:" .. name .. "@@")
    print(json)
    print("@@UIVIEW_END:" .. name .. "@@")
    return json
end

return Render
