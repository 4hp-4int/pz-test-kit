local Assert  = PZTestKit.Assert
local Recorder = require "UIView/Recorder"
local Render   = require "UIView/Render"
local VPS      = require "UIView/scenes/VPSTooltip"

do
    local panel = VPS.build()
    Render.emit(panel, panel:getWidth() + 48, panel:getHeight() + 48, "vps")
end

local tests = {}

tests["vps_tooltip_has_entries"] = function()
    local panel = VPS.build()
    return Assert.greater(#panel._entries, 0, "VPS provider produced tooltip entries")
end

return tests
