--[[ Render the SIR inventory with the search bar COLLAPSED (./uiview.sh sircollapsed),
     to diagnose the awkward empty band at the top of the list when collapsed. ]]
local Render = require "UIView/Render"
local SIRInv = require "UIView/scenes/SIRInv"
local SIR = _G.SauceInvRender

do
    SIR.Options = SIR.Options or {}
    local prev = SIR.Options.searchCollapsed
    SIR.Options.searchCollapsed = true
    local ok, err = pcall(function() Render.emit(SIRInv.build({}), nil, nil, "sircollapsed") end)
    if not ok then print("[sircollapsed] ERROR: " .. tostring(err)) end
    SIR.Options.searchCollapsed = prev
end

return {}
