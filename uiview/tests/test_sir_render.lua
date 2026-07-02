--[[
    UIView — SauceInvRender inventory rendering
    ===========================================
    Drives the REAL SIR.renderdetails over mock item stacks and asserts it paints
    a populated display list (icons / condition bars / badges). Emits the "sirinv"
    scene for the visual contact sheet (./uiview.sh sirinv).
]]

local Assert  = PZTestKit.Assert
local Render  = require "UIView/Render"
local Recorder = require "UIView/Recorder"
local SIRInv  = require "UIView/scenes/SIRInv"

-- emit the scene for headless viewing (guarded so a render error reports clearly)
do
    local ok, err = pcall(function() Render.emit(SIRInv.build({ look = "lamplight" }), nil, nil, "sirinv") end)
    pcall(function() Render.emit(SIRInv.build({}), nil, nil, "sirdaylight") end)
    pcall(function() Render.emit(SIRInv.build({ opacity = 3 }), nil, nil, "sirglass") end)
    if not ok then print("[sirinv] BUILD/EMIT ERROR: " .. tostring(err)) end
end

local function opsOf(pane)
    Render.frame(pane, pane.width + 16, pane.height + 16)
    return Recorder.ops
end
local function countOp(ops, kind)
    local n = 0
    for _, o in ipairs(ops) do if o.op == kind then n = n + 1 end end
    return n
end

local tests = {}

tests["renderdetails_runs_and_paints"] = function()
    local pane = SIRInv.build({})
    local ops = opsOf(pane)
    return Assert.greater(#ops, 20, "SIR.renderdetails produced a populated display list")
end

tests["paints_condition_bars"] = function()
    -- weapons/tools with condition draw filled rects for the bar
    local pane = SIRInv.build({})
    local ops = opsOf(pane)
    return Assert.greater(countOp(ops, "rect"), 5, "condition bars / backgrounds painted as rects")
end

tests["paints_item_icons"] = function()
    local pane = SIRInv.build({})
    local ops = opsOf(pane)
    local tex = countOp(ops, "texture")
    return Assert.greater(tex, 0, "item icons / badges painted as textures")
end

tests["paints_item_names"] = function()
    local pane = SIRInv.build({})
    local ops = opsOf(pane)
    local found = false
    for _, o in ipairs(ops) do
        if o.op == "text" and tostring(o.str):find("Pistol", 1, true) then found = true end
    end
    return Assert.isTrue(found, "item names rendered")
end

return tests
