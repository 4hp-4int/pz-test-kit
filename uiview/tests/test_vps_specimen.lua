--[[ VPS "Specimen Page" concept - a page from Morrison's Field Journal.
     ./uiview.sh vps-specimen ]]
local Render = require "UIView/Render"
local Scene  = require "UIView/scenes/VPSSpecimen"
do
    local panel = Scene.build()
    Render.emit(panel, panel:getWidth() + 80, panel:getHeight() + 60, "vps-specimen")
end
return { ["vps_specimen_renders"] = function()
    local p = Scene.build(); p:render(); return true
end }
