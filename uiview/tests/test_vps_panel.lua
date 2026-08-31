--[[
    UIView — the REAL Field Journal panel

    Emits scene "vpsjournalpanel". Where test_vps_pages judges the PAGES on a
    bare card, this mounts VorpallySauced.FieldJournalPanel itself, so the parts
    a page component knows nothing about are finally visible: the shell, the
    tabs, the Back / Close / Clear Lost buttons, and the scroll bar.

    That gap was not theoretical. The first in-game screenshot came back with
    "I see buttons which aren't rendered in the ui mocks" -- every widget
    outside the card had shipped without ever being looked at, because the only
    preview cropped them out.
]]
local Assert = PZTestKit.Assert
local Render = require "UIView/Render"
local Recorder = require "UIView/Recorder"
local Panel = require "UIView/scenes/VPSJournalPanel"

do
    Render.emit(Panel.build(), Panel.W, Panel.H, "vpsjournalpanel")
end

local function frameOps()
    Render.frame(Panel.build(), Panel.W, Panel.H)
    return Recorder.ops
end

local function textSet(ops)
    local seen = {}
    for _, op in ipairs(ops) do
        if op.op == "text" then seen[tostring(op.str)] = true end
    end
    return seen
end

local tests = {}

tests["panel_renders_its_shell_and_every_surface"] = function()
    local seen = textSet(frameOps())
    if not Assert.isTrue(seen["Morrison's Field Journal"], "the window title") then return false end
    if not Assert.isTrue(seen["THE INDEX"], "the contents page") then return false end
    if not Assert.isTrue(seen["THE ONES BEFORE"], "the memorial") then return false end
    return Assert.isTrue(seen["WHAT IT BECAME"], "and the weapon drilldown")
end

tests["panel_renders_the_buttons_the_pages_do_not_own"] = function()
    -- The whole point of this scene. A page component cannot draw these, so
    -- nothing was checking they existed, were labelled, or were chromed.
    local seen = textSet(frameOps())
    if not Assert.isTrue(seen["Close"], "Close is on the panel") then return false end
    if not Assert.isTrue(seen["Back"], "Back appears on a drilldown") then return false end
    return Assert.isTrue(seen["The Index"], "and the tabs are labelled")
end

tests["panel_tabs_hide_on_a_drilldown"] = function()
    -- A drilldown is somewhere you went FROM a tab, not a peer of one, so the
    -- tab row gives way to Back. Getting this wrong leaves both on screen and
    -- the surface reads as five tabs.
    local ops = frameOps()
    local backs, tabs = 0, 0
    for _, op in ipairs(ops) do
        if op.op == "text" then
            if op.str == "Back" then backs = backs + 1 end
            if op.str == "The Index" then tabs = tabs + 1 end
        end
    end
    -- Four panels: two are drilldowns (Back), two are tabbed views.
    if not Assert.equal(backs, 2, "Back shows on exactly the two drilldowns") then return false end
    return Assert.equal(tabs, 2, "and the tab row on exactly the two list views")
end

tests["panel_has_no_layout_collisions"] = function()
    local ops = frameOps()
    local banner
    for _, op in ipairs(ops) do
        if op.op == "text" and tostring(op.str):find("LAYOUT COLLISIONS") then
            banner = tostring(op.str)
        end
    end
    return Assert.isNil(banner, "nothing overlaps (" .. tostring(banner) .. ")")
end

return tests
