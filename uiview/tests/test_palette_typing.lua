--[[ UIView live-filter reel — emit one frame per keystroke as a query is typed into
     the REAL order box, so the list filters live (D.type runs the actual refilter).
     make_filter_gif.py stitches the frames into a GIF: the whole pitch of the mod —
     you type, it narrows. Every static shot undersells it.

     Same root across frames, so the panel stays a fixed size while the rows collapse
     within it, exactly like in game. "barricade" ties to Sauce's intro bit. ]]
local Assert  = PZTestKit.Assert
local States  = require "UIView/scenes/PaletteStates"
local Render  = require "UIView/Render"
local D       = States.D

local SEQ = { "", "b", "ba", "bar", "barr", "barri", "barric", "barrica", "barricad", "barricade" }

local tests = {}

tests["emit_filter_frames"] = function()
    local root = States.build({})            -- zero-state: full list, fixed panel size
    for i, q in ipairs(SEQ) do
        D.type(root, q)                      -- the real refilter runs here
        Render.emit(root, 1280, 800, string.format("palette_type_%02d", i - 1))
    end
    return Assert.isTrue(#root.rows >= 0, "filter frames emitted")
end

return tests
