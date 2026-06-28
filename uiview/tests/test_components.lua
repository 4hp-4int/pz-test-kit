--[[
    UIView — component gallery emit + sanity
    ========================================
    Emits the SIR component gallery (scene "components") and asserts the real
    theme-driven swatches render (chips for every category, etc.).
]]

local Assert = PZTestKit.Assert
local Render = require "UIView/Render"
local Recorder = require "UIView/Recorder"
local Comp   = require "UIView/scenes/Components"

do
    Render.emit(Comp.build(), 960, 720, "components")
end

local tests = {}

tests["gallery_renders_every_category_chip"] = function()
    Render.frame(Comp.build(), 960, 720)
    local chips = {}
    for _, op in ipairs(Recorder.ops) do
        if op.op == "text" then chips[tostring(op.str)] = true end
    end
    -- a representative spread of category chip labels
    for _, label in ipairs({ "WORLD", "CRAFT", "MED", "DRIVE", "EDIT", "INSPECT" }) do
        if not Assert.isTrue(chips[label] == true, label .. " chip painted") then return false end
    end
    return true
end

return tests
