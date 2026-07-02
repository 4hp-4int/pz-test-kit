--[[ VPS whole-journal chrome concept - Morrison's Field Journal, fully
     skinned from VPSChrome.pack.   ./uiview.sh vps-journal ]]
local Render = require "UIView/Render"
local Scene  = require "UIView/scenes/VPSJournal"
do
    local panel = Scene.build()
    Render.emit(panel, panel:getWidth() + 60, panel:getHeight() + 48, "vps-journal")
end
return { ["vps_journal_renders"] = function()
    local p = Scene.build(); p:prerender(); p:render(); return true
end }
