--[[ Emit the SIR "Lenses" POC scene for headless viewing (./uiview.sh lenses). ]]
local Render = require "UIView/Render"
local Lenses = require "UIView/scenes/Lenses"

do
    local ok, err = pcall(function()
        Render.emit(Lenses.build(), Lenses.frame.w, Lenses.frame.h, "lenses")
    end)
    if not ok then print("[lenses] BUILD/EMIT ERROR: " .. tostring(err)) end
end

return {}
