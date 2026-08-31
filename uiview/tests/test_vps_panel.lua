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
    -- NO WINDOW TITLE. A stamped "Morrison's Field Journal" across the top
    -- board cost 45px of page to name the thing the player had just opened
    -- from a menu that said the same words. Asserted as ABSENT so bringing it
    -- back is a deliberate act rather than a regression.
    if not Assert.isFalse(seen["Morrison's Field Journal"] or false,
            "no title bar; the pages get the height") then return false end
    if not Assert.isTrue(seen["THE INDEX"], "the contents page") then return false end
    if not Assert.isTrue(seen["THE ONES BEFORE"], "the memorial") then return false end
    return Assert.isTrue(seen["THE STIRRING"], "and the weapon drilldown")
end

--- THE SPREAD IS TILED PAPER, AND A TILE MUST NOT BE STRETCHED.
---
--- This is the bug that got past every other check. Chrome.tile hand-rolled
--- its own loop and clamped the DESTINATION rect at the sheet edge before
--- calling drawTextureScaled -- which has no source crop, so the last column
--- held the whole 512px paper texture compressed into the leftover 334px. The
--- grain changed frequency mid-page and the boundary landed a few pixels
--- outside the fold, so it read as a second crease beside the real one.
---
--- The preview could not show it either, because getTexture used to claim
--- 32x32 for everything: the same code tiled at 32px here, the remainder was
--- 13px, and the artifact was sub-pixel. One fold on screen here, two in game.
---
--- So the assertion is on the OP KIND, not on pixels: paper and leather go
--- through the engine's tiler, which crops. Any scaled draw of a tile is the
--- old bug returning.
tests["panel_tiles_paper_and_leather_without_stretching_them"] = function()
    local ops = frameOps()
    local tiled, stretched = 0, 0
    for _, op in ipairs(ops) do
        local name = tostring(op.name or "")
        if name:find("_tile", 1, true) then
            if op.op == "texture_tiled" then
                tiled = tiled + 1
            elseif op.op == "texture" then
                stretched = stretched + 1
            end
        end
    end
    if not Assert.isTrue(tiled > 0,
            "the sheet and the boards are drawn with the engine tiler") then
        return false
    end
    return Assert.equal(stretched, 0,
        "no tile is drawn through a scaling draw (found " .. stretched .. ")")
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
