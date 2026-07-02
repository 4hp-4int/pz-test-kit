--[[
    UIView/Interact — event dispatch for the headless widget tree
    =============================================================
    Step 1 of docs/INTERACTIVE.md: drive the REAL widget callbacks the way
    PZ's UIManager would -- topmost-first hit-testing, element-local coords,
    mouse state via UIView_setMouse -- so interaction paths (chip clicks,
    collapse chevrons, sort headers) run in tests today and in the live
    browser bridge later. No server here: pure dispatch.
]]

local Interact = {}

local function visible(el)
    if not el then return false end
    if el._visible == false then return false end
    if el.isVisible and not el:isVisible() then return false end
    return true
end

local function contains(el, x, y)
    if not visible(el) then return false end
    local ax, ay = el:getAbsoluteX(), el:getAbsoluteY()
    return x >= ax and x < ax + (el.width or 0)
       and y >= ay and y < ay + (el.height or 0)
end

-- Topmost element under (x,y): children beat parents, later siblings beat
-- earlier ones (they draw on top).
function Interact.hit(root, x, y)
    if not contains(root, x, y) then return nil end
    local kids = root.childrenInOrder or {}
    for i = #kids, 1, -1 do
        local h = Interact.hit(kids[i], x, y)
        if h then return h end
    end
    return root
end

-- Click: hit-test, then bubble from the hit element upward until someone
-- defines a mouse handler. Fires onMouseDown then onMouseUp (PZ order;
-- ISButton fires its onclick from onMouseUp). Returns the element that
-- handled it, or nil.
function Interact.click(root, x, y)
    if UIView_setMouse then UIView_setMouse(x, y) end
    local el = Interact.hit(root, x, y)
    local cur = el
    while cur do
        if cur.onMouseDown or cur.onMouseUp then
            local ax, ay = cur:getAbsoluteX(), cur:getAbsoluteY()
            if cur.onMouseDown then
                pcall(function() cur:onMouseDown(x - ax, y - ay) end)
            end
            if cur.onMouseUp then
                pcall(function() cur:onMouseUp(x - ax, y - ay) end)
            end
            return cur
        end
        cur = cur.parent
    end
    return nil
end

-- Wheel: bubble from the element under the mouse to the first onMouseWheel.
-- del follows PZ convention (positive = down).
function Interact.wheel(root, x, y, del)
    if UIView_setMouse then UIView_setMouse(x, y) end
    local cur = Interact.hit(root, x, y)
    while cur do
        if cur.onMouseWheel then
            local handled
            pcall(function() handled = cur:onMouseWheel(del) end)
            if handled ~= false then return cur end
        end
        cur = cur.parent
    end
    return nil
end

-- Type into a text entry: set the text (the mock buffer; hosts poll it, as
-- SIR's search bar does each prerender) and deliver a non-text key if given
-- (Escape etc. route through onOtherKey, like the real UITextBox2).
function Interact.type(entry, text, key)
    if not entry then return end
    if text ~= nil and entry.setText then entry:setText(text) end
    if key and entry.onOtherKey then
        pcall(function() entry.onOtherKey(entry, key) end)
    end
end

return Interact
