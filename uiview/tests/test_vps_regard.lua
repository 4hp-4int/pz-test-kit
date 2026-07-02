--[[ VPS "Regard" panel — design scene for the dedicated weapon-soul surface.
     ./uiview.sh vps-regard  -> out/view.html
     python capture_panel.py shots/vps-regard.png ]]

local Assert = PZTestKit.Assert
local Render = require "UIView/Render"
local Scene  = require "UIView/scenes/VPSRegard"

do
    local panel = Scene.build()
    Render.emit(panel, panel:getWidth() + 80, panel:getHeight() + 60, "vps-regard")
end

local tests = {}

tests["vps_regard_measures_and_renders"] = function()
    local panel = Scene.build()
    if not Assert.greater(panel.height, 200, "panel measured a real height") then return false end
    panel:render()  -- must not throw
    return true
end

return tests
