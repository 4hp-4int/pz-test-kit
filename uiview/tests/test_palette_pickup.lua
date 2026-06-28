--[[
    UIView — pal_pickup (grab floor items)
    ======================================
    Drives the real `pickup` source collect() with world-inventory items placed
    on the player's tile. Asserts identical types collapse into one "Pick Up X (N)"
    row that grabs them all, and an empty area yields nothing.
]]

local Assert = PZTestKit.Assert
local Fixtures = PZTestKit.Fixtures
local SP = require "palette/pal_pickup"

local function pickupCollect()
    for _, s in ipairs(SP.sources) do if s.id == "pickup" then return s.collect end end
end

-- Build a world with the given item fulltypes lying on the player's tile.
local function collect(fulltypes)
    _G.ISWorldObjectContextMenu = { onGrabWItem = function() end }
    local world = Fixtures.world()
    local center = world:square(10, 10, 0)
    for _, ft in ipairs(fulltypes) do
        local item = Fixtures.item({ fullType = ft })
        local wi = Fixtures.worldItem(item, center)
        table.insert(center._private.worldObjects, wi)
    end
    _G._pz_player = Fixtures.player({ square = center })
    return pickupCollect()(0)
end

local function find(cmds, sub)
    for _, c in ipairs(cmds) do
        if tostring(c.label):find(sub, 1, true) then return c end
    end
    return nil
end

local tests = {}

tests["grabs_floor_item"] = function()
    local cmds = collect({ "Base.Hammer" })
    return Assert.notNil(find(cmds, "Hammer"), "a floor item produces a Pick Up row")
end

tests["collapses_identical_types_with_count"] = function()
    local cmds = collect({ "Base.Nails", "Base.Nails", "Base.Nails" })
    local row = find(cmds, "Nails")
    if not Assert.notNil(row, "Pick Up Nails row exists") then return false end
    -- one row for three stacks, labelled with the count
    if not Assert.equal(#cmds, 1, "three identical stacks collapse to ONE row") then return false end
    return Assert.notNil(tostring(row.label):find("3", 1, true), "the row shows the count (3)")
end

tests["distinct_types_distinct_rows"] = function()
    local cmds = collect({ "Base.Nails", "Base.Hammer" })
    if not Assert.notNil(find(cmds, "Nails"), "Nails row") then return false end
    return Assert.notNil(find(cmds, "Hammer"), "Hammer row")
end

tests["empty_area_no_rows"] = function()
    return Assert.equal(#collect({}), 0, "nothing on the floor -> no pickup rows")
end

tests["pickup_rows_runnable_and_grab_category"] = function()
    local cmds = collect({ "Base.Hammer" })
    local row = find(cmds, "Hammer")
    if not Assert.isTrue(row.runnable == true, "a present floor item is runnable") then return false end
    return Assert.equal(row.category, "grab", "pickup rows are the 'grab' category")
end

return tests
