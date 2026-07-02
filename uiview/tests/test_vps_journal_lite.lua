--[[ VPS journal-lite chrome concept - modern flat chrome that still reads
     "journal"; the contrast piece to test_vps_journal's full leather book.
     ./uiview.sh vps-journal-lite ]]
local Render = require "UIView/Render"
local Scene  = require "UIView/scenes/VPSJournalLite"
do
    local panel = Scene.build()
    Render.emit(panel, panel:getWidth() + 60, panel:getHeight() + 48, "vps-journal-lite")
end
return { ["vps_journal_lite_renders"] = function()
    local p = Scene.build(); p:prerender(); p:render(); return true
end }
