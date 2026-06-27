--[[
    UIView — pal_highlight (outline the selected row's world target)
    ================================================================
    SP.Highlight.set/clear drive vanilla's IsoObject outline calls. We stub the
    object to record on/off, and assert: set lights the object, swapping clears the
    previous and lights the new, set to the same object is a no-op (safe per-frame),
    clear turns it off, and a nil target just clears.
]]

local Assert = PZTestKit.Assert
local SP = require "palette/pal_highlight"
local H = SP.Highlight

-- the engine highlight colour the module reads from getCore() (override the
-- harness's getCore so getObjectHighlitedColor is present for this test).
local _origGetCore = _G.getCore
_G.getCore = function()
    local core = (_origGetCore and _origGetCore()) or {}
    core.getObjectHighlitedColor = core.getObjectHighlitedColor or function()
        return { getR = function() return 0.6 end, getG = function() return 0.8 end, getB = function() return 1.0 end }
    end
    return core
end

-- a fake IsoObject recording its outline/highlight state
local function obj()
    local o = { _type = "IsoObject", lit = false, outline = false, col = nil }
    o.setHighlighted       = function(self, pnum, on) self.lit = on end
    o.setOutlineHighlight  = function(self, pnum, on) self.outline = on end
    o.setOutlineHighlightCol = function(self, pnum, r, g, b, a) self.col = { r, g, b, a } end
    return o
end

local tests = {}

tests["set_lights_the_object"] = function()
    H.clear()
    local a = obj()
    H.set(0, a)
    if not Assert.isTrue(a.outline == true, "outline turned on") then return false end
    return Assert.isTrue(a.lit == true, "highlight turned on")
end

tests["set_applies_engine_colour"] = function()
    H.clear()
    local a = obj()
    H.set(0, a)
    return Assert.isTrue(a.col ~= nil and a.col[3] == 1.0, "vanilla object-highlight colour applied")
end

tests["swap_clears_previous_lights_new"] = function()
    H.clear()
    local a, b = obj(), obj()
    H.set(0, a)
    H.set(0, b)
    if not Assert.isTrue(a.outline == false, "previous object cleared on swap") then return false end
    return Assert.isTrue(b.outline == true, "new object lit on swap")
end

tests["same_object_is_noop"] = function()
    H.clear()
    local a = obj()
    H.set(0, a)
    a.outline = "sentinel"             -- if set() re-paints, this gets overwritten to true
    H.set(0, a)                        -- same target, same player
    return Assert.equal(a.outline, "sentinel", "re-setting the same object does nothing (safe per-frame)")
end

tests["clear_turns_off"] = function()
    H.clear()
    local a = obj()
    H.set(0, a)
    H.clear()
    return Assert.isTrue(a.outline == false, "clear() turns the outline off")
end

tests["set_nil_clears"] = function()
    H.clear()
    local a = obj()
    H.set(0, a)
    H.set(0, nil)
    return Assert.isTrue(a.outline == false, "selecting a row with no world target clears the highlight")
end

-- a tile-targeted action (plow / scrub a tile) sets hl to the SQUARE; the highlight
-- resolves it to the square's floor IsoObject so the tile lights up.
tests["square_target_lights_its_floor"] = function()
    H.clear()
    local floor = obj()
    local sq = { _type = "IsoGridSquare", getFloor = function() return floor end }
    H.set(0, sq)
    if not Assert.isTrue(floor.outline == true, "a square target lights its floor tile") then return false end
    -- re-setting the same square is still a no-op (resolves to the same floor)
    floor.outline = "sentinel"
    H.set(0, sq)
    return Assert.equal(floor.outline, "sentinel", "same square -> same floor -> no re-paint")
end

return tests
