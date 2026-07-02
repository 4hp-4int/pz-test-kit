--[[ VPS kill-clock iteration sheet. ./uiview.sh vps-clocks ]]
local Render = require "UIView/Render"
local Scene  = require "UIView/scenes/VPSClocks"
do
    local panel = Scene.build()
    Render.emit(panel, panel:getWidth() + 40, panel:getHeight() + 40, "vps-clocks")
end
return { ["vps_clocks_renders"] = function()
    local p = Scene.build(); p:render(); return true
end }
