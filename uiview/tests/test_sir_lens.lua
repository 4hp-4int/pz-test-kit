--[[ Emit the SIR inventory under each lens (real SIR.renderdetails -> SIR.Lens):
       ./uiview.sh sirlens             COMBAT
       ./uiview.sh sirlens-survival    SURVIVAL
       ./uiview.sh sirlens-logistics   LOGISTICS ]]
local Render = require "UIView/Render"
local SIRInv = require "UIView/scenes/SIRInv"
local SIR = _G.SauceInvRender

local function emitLens(lensId, name, fixture)
    local ok, err = pcall(function()
        SIR.Lens.set(lensId)
        Render.emit(SIRInv.build({ fixture = fixture }), nil, nil, name)
        SIR.Lens.set(0)
    end)
    if not ok then print("[" .. name .. "] BUILD/EMIT ERROR: " .. tostring(err)) end
end

if SIR and SIR.Lens then
    emitLens("combat",    "sirlens")
    emitLens("survival",  "sirlens-survival")
    emitLens("logistics", "sirlens-logistics")
    -- carpentry-heavy bag so the profession lens shows real work
    emitLens("woodwork",  "sirlens-woodwork", "woodwork")
end

return {}
