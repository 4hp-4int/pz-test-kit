--[[
    UIView — SIR tooltip dress on the REAL TooltipLib object tooltip
    ================================================================
    Renders the Tooltip scene with sauce-invrender's panel dress registered
    (TooltipDress scene) and asserts the box swap: the sauce_ledger_* nine
    paints the card, the flat full-panel rect + square border are gone, and
    the content (title, rows) still renders on top. Emits the "tooltipdress"
    golden, then CLEARS the dress so later files' scenes render the flat box.
]]

local Assert      = PZTestKit.Assert
local Recorder    = require "UIView/Recorder"
local Render      = require "UIView/Render"
local TooltipDress = require "UIView/scenes/TooltipDress"

do
    local panel = TooltipDress.build()
    Render.emit(panel, panel:getWidth() + 48, panel:getHeight() + 48, "tooltipdress")
    TooltipDress.teardown()   -- top-level: later files' emits stay flat
end

local function findOp(pred)
    for _, op in ipairs(Recorder.ops) do
        if pred(op) then return op end
    end
    return nil
end

local function buildFrame()
    local panel = TooltipDress.build()
    Render.frame(panel, panel:getWidth() + 48, panel:getHeight() + 48)
    return panel
end

local tests = {}

tests["ledger_nine_paints_the_card"] = function()
    local panel = buildFrame()
    local ok = Assert.notNil(findOp(function(op)
        return op.op == "texture" and tostring(op.name) == "sauce_ledger_tl"
    end), "kraft ledger corner painted")
    ok = Assert.notNil(findOp(function(op)
        return op.op == "texture" and tostring(op.name) == "sauce_ledger_c"
    end), "kraft ledger centre painted") and ok
    TooltipDress.teardown()
    return ok
end

tests["flat_box_suppressed_under_dress"] = function()
    local panel = buildFrame()
    local w, h = panel:getWidth(), panel:getHeight()
    -- the old background was a full-panel rect + a full-panel border
    local ok = Assert.isNil(findOp(function(op)
        return op.op == "rect" and op.w == w and op.h == h
    end), "full-panel flat bg rect gone")
    ok = Assert.isNil(findOp(function(op)
        return op.op == "rectborder" and op.w == w and op.h == h
    end), "full-panel square border gone") and ok
    TooltipDress.teardown()
    return ok
end

tests["content_still_renders_on_the_card"] = function()
    buildFrame()
    local ok = Assert.notNil(findOp(function(op)
        return op.op == "text" and tostring(op.str):find("Portable Generator", 1, true)
    end), "title painted over the dress")
    TooltipDress.teardown()
    return ok
end

tests["teardown_returns_the_flat_box"] = function()
    local panel = TooltipDress.build()
    TooltipDress.teardown()   -- clear BEFORE the frame: prerender sees no dress
    Render.frame(panel, panel:getWidth() + 48, panel:getHeight() + 48)
    local w, h = panel:getWidth(), panel:getHeight()
    local ok = Assert.notNil(findOp(function(op)
        return op.op == "rect" and op.w == w and op.h == h
    end), "flat bg rect back after clearPanelDress")
    ok = Assert.isNil(findOp(function(op)
        return op.op == "texture" and tostring(op.name) == "sauce_ledger_c"
    end), "no ledger nine without the dress") and ok
    return ok
end

return tests
