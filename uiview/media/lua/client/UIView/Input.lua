--[[
    UIView — Input injection / hit-testing
    ======================================
    Drives a headless element tree the way the game's mouse pipeline does:
    find the topmost visible element under (x,y), then call the matching
    handler (onMouseDown/onMouseUp/onMouseMove/onMouseWheel). Mouse position is
    pushed into the mock so isMouseOver()/getMouseX() reflect it during the next
    render.

    Typical test loop:
        Input.move(root, 40, 12)          -- hover
        local frame0 = Render.frame(root) -- capture
        Input.click(root, 40, 12)         -- press+release on topmost hit
        local frame1 = Render.frame(root) -- capture reaction
]]

local Input = {}

-- Depth-first topmost hit: last painted child over the point wins.
local function hitTest(el, sx, sy)
    if el == nil then return nil end
    if el.isVisible and el:isVisible() == false then return nil end
    if not el:isPointOver(sx, sy) then return nil end
    local kids = el.childrenInOrder or {}
    for i = #kids, 1, -1 do
        local hit = hitTest(kids[i], sx, sy)
        if hit then return hit end
    end
    return el
end

Input.hitTest = hitTest

function Input.move(root, sx, sy)
    UIView_setMouse(sx, sy)
    local target = hitTest(root, sx, sy)
    if target and target.onMouseMove then
        pcall(target.onMouseMove, target, 0, 0)
    end
    return target
end

local function localCoords(el, sx, sy)
    return sx - el:getAbsoluteX(), sy - el:getAbsoluteY()
end

function Input.down(root, sx, sy, button)
    UIView_setMouse(sx, sy)
    local target = hitTest(root, sx, sy)
    if not target then return nil end
    local lx, ly = localCoords(target, sx, sy)
    local handler = (button == "right") and target.onRightMouseDown or target.onMouseDown
    if handler then pcall(handler, target, lx, ly) end
    return target
end

function Input.up(root, sx, sy, button)
    UIView_setMouse(sx, sy)
    local target = hitTest(root, sx, sy)
    if not target then return nil end
    local lx, ly = localCoords(target, sx, sy)
    local handler = (button == "right") and target.onRightMouseUp or target.onMouseUp
    if handler then pcall(handler, target, lx, ly) end
    return target
end

--- Full press+release on the topmost element under the point.
function Input.click(root, sx, sy, button)
    Input.down(root, sx, sy, button)
    return Input.up(root, sx, sy, button)
end

function Input.wheel(root, sx, sy, delta)
    UIView_setMouse(sx, sy)
    local target = hitTest(root, sx, sy)
    if target and target.onMouseWheel then pcall(target.onMouseWheel, target, delta) end
    return target
end

return Input
