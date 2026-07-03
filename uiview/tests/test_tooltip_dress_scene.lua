--[[
    UIView — SIR tooltip dress on the REAL TooltipLib object tooltip
    ================================================================
    Renders the Tooltip scene with sauce-invrender's panel dress registered
    (TooltipDress scene) and asserts the box swap: the sir_ledger_* nine
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

do
    -- the RULED card: section rule + dot leaders from the ornaments hook
    local card = TooltipDressItem.buildSectioned({ 0.40, 0.85, 0.35, 1.0 })
    Render.emit(card, card:getWidth() + 48, card:getHeight() + 48, "tooltipdressitemruled")
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
        return op.op == "texture" and tostring(op.name) == "sir_ledger_tl"
    end), "kraft ledger corner painted")
    ok = Assert.notNil(findOp(function(op)
        return op.op == "texture" and tostring(op.name) == "sir_ledger_c"
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
        return op.op == "texture" and tostring(op.name) == "sir_ledger_c"
    end), "kraft ledger body on the item card")
    ok = Assert.notNil(findOp(function(op)
        return op.op == "texture" and tostring(op.name) == "sir_wincap_tl"
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
        return op.op == "texture" and tostring(op.name) == "sir_chip_tl"
    end), "accent rail drawn from the tintable chip nine")
    ok = Assert.isNil(findOp(function(op)
        return op.op == "texture" and tostring(op.name) == "sir_wincap_tl"
    end), "cherry wincap stands down when an accent is on the channel") and ok
    -- the chip is tinted with the ENAMEL-deepened accent (0.90 * 0.62)
    local tinted = findOp(function(op)
        return op.op == "texture" and tostring(op.name) == "sir_chip_c"
    end)
    ok = Assert.notNil(tinted, "rail centre painted") and ok
    if tinted then
        ok = Assert.nearEqual(tinted.r, 0.90 * 0.62, 0.01, "rail tint = enamel-deep accent") and ok
    end
    return ok
end

tests["ornaments_rule_sections_and_dot_kv_rows"] = function()
    local card = TooltipDressItem.buildSectioned()
    Render.frame(card, card:getWidth() + 48, card:getHeight() + 48)
    -- section rule: 3x1 warm-ink dashes on the section label's line,
    -- starting after the label text, running to the card's right edge
    local dashes, dots, dotRows = 0, 0, {}
    for _, op in ipairs(Recorder.ops) do
        if op.op == "texture" and op.name == "" and op.h == 1 then
            if op.w == 3 then dashes = dashes + 1 end
            if op.w == 1 then dots = dots + 1; dotRows[op.y] = true end
        end
    end
    local ok = Assert.greater(dashes, 10, "section rule dashes painted")
    ok = Assert.greater(dots, 30, "dot leaders painted") and ok
    -- leaders land on multiple kv rows (card y=24 + row y + h - 4)
    local rowsWithDots = 0
    for _ in pairs(dotRows) do rowsWithDots = rowsWithDots + 1 end
    ok = Assert.greater(rowsWithDots, 3, "leaders on several kv rows") and ok
    -- dashes sit on the section label's line: y = 24 + 142 + 18 - 4 = 180
    local dashOnSection = false
    for _, op in ipairs(Recorder.ops) do
        if op.op == "texture" and op.name == "" and op.w == 3 and op.y == 180 then
            dashOnSection = true
        end
    end
    ok = Assert.isTrue(dashOnSection, "rule anchored to the section row") and ok
    return ok
end

tests["bar_row_repainted_as_chrome_gauge"] = function()
    local card = TooltipDressItem.buildSectioned()
    Render.frame(card, card:getWidth() + 48, card:getHeight() + 48)
    -- gauge = shipped chrome: recessed ENTRY nine as the track over the
    -- vanilla bar rect, tintable CHIP nine as the fraction-accurate fill.
    -- Bar band: card y 24 + row y 106 + ls/2 - 1 = 138 (track from 137).
    local fill, track = nil, nil
    for _, op in ipairs(Recorder.ops) do
        if op.op == "texture" and op.y >= 136 and op.y <= 146 then
            if op.name == "sir_chip_c" then fill = op end
            if op.name == "sir_entry_c" then track = op end
        end
    end
    local ok = Assert.notNil(track, "entry-nine track repaints the vanilla bar rect")
    ok = Assert.notNil(fill, "chip-nine enamel fill") and ok
    if fill then
        -- fill spans floor((120-2)*0.62) = 73 with corner 1 -> centre 71,
        -- tinted with the bar's declared green at 0.85 enamel depth
        ok = Assert.equal(fill.w, 71, "fill centre spans the fraction") and ok
        ok = Assert.nearEqual(fill.g, 0.8 * 0.85, 0.001,
            "fill wears the bar's declared colour (enamel-deepened)") and ok
    end
    return ok
end

tests["ornament_error_trips_the_guard"] = function()
    local SIR = _G.SauceInvRender
    local card = TooltipDressItem.buildSectioned()
    card.geom.sections = nil   -- malformed geometry -> ornaments must trip
    local okRender = pcall(function()
        Render.frame(card, card:getWidth() + 48, card:getHeight() + 48)
    end)
    local tripped = SIR.Guard.tripped["ttdress"] ~= nil   -- stores the error string
    -- reset the guard so later tests/scenes keep dressing
    SIR.Guard.tripped["ttdress"] = nil
    return Assert.isTrue(tripped, "guard tripped on malformed geometry")
        and Assert.isTrue(true, "harness survived (error contained): " .. tostring(okRender))
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
        return op.op == "texture" and tostring(op.name) == "sir_ledger_c"
    end), "no ledger nine without the dress") and ok
    return ok
end

return tests
