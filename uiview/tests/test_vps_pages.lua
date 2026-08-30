--[[
    UIView — the journal's three surfaces

    Emits scene "vpspages". The assertion that matters is COLLISION-FREE at
    three different page contents: a page whose text overlaps renders without
    complaint and looks like a font bug, which is how "Vol. VIIIBLOODED"
    survived a passing suite.
]]
local Assert = PZTestKit.Assert
local Render = require "UIView/Render"
local Recorder = require "UIView/Recorder"
local Pages = require "UIView/scenes/VPSJournalPages"

do
    Render.emit(Pages.build(), Pages.W, Pages.H, "vpspages")
end

local tests = {}

tests["pages_render_all_three_surfaces"] = function()
    Render.frame(Pages.build(), Pages.W, Pages.H)
    local seen = {}
    for _, op in ipairs(Recorder.ops) do
        if op.op == "text" then seen[tostring(op.str)] = true end
    end
    if not Assert.isTrue(seen["IN YOUR HANDS"], "the held weapon page") then return false end
    if not Assert.isTrue(seen["THE INDEX"], "the contents page") then return false end
    return Assert.isTrue(seen["THE ONES BEFORE"], "the memorial page")
end

tests["pages_have_no_layout_collisions"] = function()
    -- No banner means no overlapping text on any of the three.
    Render.frame(Pages.build(), Pages.W, Pages.H)
    local banner
    for _, op in ipairs(Recorder.ops) do
        if op.op == "text" and tostring(op.str):find("LAYOUT COLLISIONS") then
            banner = tostring(op.str)
        end
    end
    return Assert.isNil(banner, "no page collides (" .. tostring(banner) .. ")")
end

tests["memorial_strikes_lost_bonds_rather_than_dimming"] = function()
    -- A strike is a RECT drawn over the name. Dimming would read as "less
    -- important"; the strike reads as "this happened and is over", which is
    -- what makes it a memorial instead of a table.
    Render.frame(Pages.build(), Pages.W, Pages.H)
    local rects = 0
    for _, op in ipairs(Recorder.ops) do
        if op.op == "rect" and (op.h or 0) == 1 then rects = rects + 1 end
    end
    return Assert.isTrue(rects >= 3, ("lost bonds are struck through (%d rules)"):format(rects))
end

return tests
