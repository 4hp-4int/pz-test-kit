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
local TooltipDressItem = require "UIView/scenes/TooltipDressItem"

do
    local panel = TooltipDress.build()
    Render.emit(panel, panel:getWidth() + 48, panel:getHeight() + 48, "tooltipdress")
    TooltipDress.teardown()   -- top-level: later files' emits stay flat
end

do
    local card = TooltipDressItem.build()
    Render.emit(card, card:getWidth() + 48, card:getHeight() + 48, "tooltipdressitem")
end

do
    -- SauceTooltips' firearm red on the accent channel -> the rail wears it
    local card = TooltipDressItem.build({ 0.90, 0.30, 0.30, 1.0 })
    Render.emit(card, card:getWidth() + 48, card:getHeight() + 48, "tooltipdressitemaccent")
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

tests["item_card_wears_ledger_and_cherry_rail"] = function()
    local card = TooltipDressItem.build()
    Render.frame(card, card:getWidth() + 48, card:getHeight() + 48)
    local ok = Assert.notNil(findOp(function(op)
        return op.op == "texture" and tostring(op.name) == "sauce_ledger_c"
    end), "kraft ledger body on the item card")
    ok = Assert.notNil(findOp(function(op)
        return op.op == "texture" and tostring(op.name) == "sauce_wincap_tl"
    end), "cherry title rail on the item card") and ok
    ok = Assert.notNil(findOp(function(op)
        return op.op == "text" and tostring(op.str):find("Frying Pan", 1, true)
    end), "name ink painted over the rail") and ok
    return ok
end

tests["accent_rail_replaces_cherry_on_the_item_card"] = function()
    local card = TooltipDressItem.build({ 0.90, 0.30, 0.30, 1.0 })
    Render.frame(card, card:getWidth() + 48, card:getHeight() + 48)
    local ok = Assert.notNil(findOp(function(op)
        return op.op == "texture" and tostring(op.name) == "sauce_chip_tl"
    end), "accent rail drawn from the tintable chip nine")
    ok = Assert.isNil(findOp(function(op)
        return op.op == "texture" and tostring(op.name) == "sauce_wincap_tl"
    end), "cherry wincap stands down when an accent is on the channel") and ok
    -- the chip is tinted with the ENAMEL-deepened accent (0.90 * 0.62)
    local tinted = findOp(function(op)
        return op.op == "texture" and tostring(op.name) == "sauce_chip_c"
    end)
    ok = Assert.notNil(tinted, "rail centre painted") and ok
    if tinted then
        ok = Assert.nearEqual(tinted.r, 0.90 * 0.62, 0.01, "rail tint = enamel-deep accent") and ok
    end
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
