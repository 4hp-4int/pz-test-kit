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
    -- "IN YOUR HANDS" was a fourth surface, deliberately removed: you may not be
    -- holding a weapon when you open the journal, so a page about the one in
    -- your hands is a page that is often about nothing. The assertion outlived
    -- the surface and had been failing ever since.
    if not Assert.isTrue(seen["THE INDEX"], "the contents page") then return false end
    if not Assert.isTrue(seen["THE ONES BEFORE"], "the memorial page") then return false end
    -- The volume page has NO contents heading. "Marks" was the third place on
    -- screen saying the same word, so the tier bands lead instead -- and a
    -- band is what identifies the page now.
    return Assert.isTrue(seen["Faint"] or seen["Strong"] or seen["Violent"]
        or seen["Consuming"] or seen["Blooded"], "and a volume, reread")
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
