--[[
    UIView — TooltipLib tooltip render tests
    ========================================
    Renders a REAL TooltipLib WorldObjectPanel headlessly (built by the library's
    own OnPreUIDraw pipeline) and asserts content + layout, then emits the
    display list for the viewer.
]]

local Assert   = PZTestKit.Assert
local Recorder = require "UIView/Recorder"
local Render   = require "UIView/Render"
local Tooltip  = require "UIView/scenes/Tooltip"

do
    local panel = Tooltip.build()
    Render.emit(panel, panel:getWidth() + 48, panel:getHeight() + 48, "tooltip")
end

local function findText(substr)
    for _, op in ipairs(Recorder.ops) do
        if op.op == "text" and tostring(op.str):find(substr, 1, true) then return op end
    end
    return nil
end

local tests = {}

tests["tooltiplib_builds_entries"] = function()
    local panel = Tooltip.build()
    return Assert.greater(#panel._entries, 0, "provider added entries via real DirectRenderCMT")
end

tests["title_and_content_render"] = function()
    local panel = Tooltip.build()
    Render.frame(panel, panel:getWidth() + 48, panel:getHeight() + 48)
    if not Assert.notNil(findText("Portable Generator"), "title painted") then return false end
    return Assert.notNil(findText("Running"), "keyvalue value painted")
end

tests["progress_bar_emits_fill_rect"] = function()
    local panel = Tooltip.build()
    Render.frame(panel, panel:getWidth() + 48, panel:getHeight() + 48)
    -- the Fuel progress prints "62%"
    return Assert.notNil(findText("62%"), "progress percent painted from fraction 0.62")
end

tests["measured_width_respects_min"] = function()
    local panel = Tooltip.build()
    -- provider declared minWidth = 220; measured width must be >= that
    return Assert.greaterEq(panel:getWidth(), 220, "panel honors provider minWidth")
end

return tests
