--[[ pal_place — enumerate Moveable furniture in the inventory tree and hand off to
     the placement cursor. Was 26% covered. Tests: only Moveables become rows, dedup
     by fulltype, and running a row opens the cursor without error. ]]
local Assert    = PZTestKit.Assert
local CraftMock = require "UIView/CraftMock"
require "palette/pal_place"
local SP = _G.SaucePalette
local P  = SP.Place

local function moveable(ft, name)
    return {
        _type          = "Moveable",
        getFullType    = function() return ft end,
        getDisplayName = function() return name end,
        getTexture     = function() return nil end,
        getContainer   = function() return { getContainingItem = function() return nil end } end,
    }
end

-- install CraftMock (player + inventory of `items`) plus the cursor/cell globals.
local function placeEnv(items, fn)
    CraftMock.install(items)
    local sCur, sCell = _G.ISMoveableCursor, _G.getCell
    _G.ISMoveableCursor = { new = function() return {
        player = 0, setMoveableMode = function() end, tryInitialItem = function() end } end }
    _G.getCell = function() return { setDrag = function() end } end
    local ok, err = pcall(fn)
    _G.ISMoveableCursor, _G.getCell = sCur, sCell
    CraftMock.restore()
    if not ok then error(err) end
end

local tests = {}

tests["enumerates_moveables_only"] = function()
    local cmds
    placeEnv({ moveable("Base.Fridge", "Fridge"), CraftMock.item("Base.Nails") }, function()
        cmds = P.collect(0)
    end)
    if not Assert.equal(#cmds, 1, "one place row (the fridge), not the nails") then return false end
    local c = cmds[1]
    if not Assert.equal(c.category, "place", "place category") then return false end
    if not Assert.equal(c.cursor, true, "hands off to a placement cursor") then return false end
    return Assert.equal(c.label, "Place: Fridge", "labelled by the moveable")
end

tests["dedupes_by_fulltype"] = function()
    local cmds
    placeEnv({ moveable("Base.Fridge", "Fridge"), moveable("Base.Fridge", "Fridge") }, function()
        cmds = P.collect(0)
    end)
    return Assert.equal(#cmds, 1, "two identical fridges collapse to one row")
end

tests["run_opens_the_cursor_without_error"] = function()
    local ranOk
    placeEnv({ moveable("Base.Fridge", "Fridge") }, function()
        local cmds = P.collect(0)
        ranOk = pcall(function() cmds[1].run() end)
    end)
    return Assert.equal(ranOk, true, "running a place row opens the moveable cursor cleanly")
end

return tests
