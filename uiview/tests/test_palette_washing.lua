--[[
    UIView — pal_washing (scrub blood/dirt at a water source)
    =========================================================
    Drives the real washing collect() against a stubbed water world +
    ISWorldObjectContextMenu.onWashClothing/onWashYourself. Asserts: no source -> no
    family; near a source, Wash Yourself is always offered; a bloody/dirty item yields
    Wash All (default) + a per-item row; clean inventory offers only Wash Yourself; the
    rows highlight the source and carry the wash category; Wash All replays the handler.
]]

local Assert = PZTestKit.Assert
local SP = require "palette/pal_washing"

local function list(items)
    return { size = function() return #items end, get = function(_, i) return items[i + 1] end }
end

-- a clothing item with a blood level + dirtiness.
local function clothing(name, blood, dirt)
    return {
        _type = "Clothing",
        getName = function() return name end,
        getTexture = function() return nil end,
        getBloodLevel = function() return blood or 0 end,
        getDirtiness = function() return dirt or 0 end,
    }
end

-- set up a stubbed water world; returns (sink, restore, washCalls).
local function washWorld(present)
    local sink = { _type = "IsoObject", hasWater = function() return present ~= false end }
    local sq = { getX = function() return 0 end, getY = function() return 0 end, getZ = function() return 0 end,
                 getObjects = function() return list({ sink }) end }
    local oCell, oMenu = _G.getCell, _G.ISWorldObjectContextMenu
    local calls = { wash = 0, self = 0 }
    _G.getCell = function() return { getGridSquare = function(_, x, y) if x == 0 and y == 0 then return sq end end } end
    _G.ISWorldObjectContextMenu = {
        onWashClothing = function() calls.wash = calls.wash + 1 end,
        onWashYourself = function() calls.self = calls.self + 1 end,
    }
    _G.ArrayList = _G.ArrayList or { new = function() return { add = function() end, size = function() return 0 end } end }
    local function restore() _G.getCell, _G.ISWorldObjectContextMenu = oCell, oMenu end
    return sink, restore, calls
end

local function collect(items, sink)
    local inv = { getItems = function() return list(items) end }
    local p = { _type = "IsoPlayer", getInventory = function() return inv end,
                getCurrentSquare = function() return sink and { getX = function() return 0 end,
                    getY = function() return 0 end, getZ = function() return 0 end } or nil end }
    _G._pz_player = p
    for _, s in ipairs(SP.sources) do if s.id == "washing" then return s.collect(0) end end
end

local function find(cmds, sub)
    for _, c in ipairs(cmds) do if tostring(c.label):find(sub, 1, true) then return c end end
    return nil
end

local tests = {}

tests["no_source_no_family"] = function()
    local sink, restore = washWorld()
    -- player not on the water square -> nearestSource returns nil
    local cmds = collect({ clothing("Jeans", 0.5, 0) }, nil)
    restore()
    return Assert.equal(#cmds, 0, "no nearby water -> no wash rows")
end

tests["source_always_offers_wash_yourself"] = function()
    local sink, restore = washWorld()
    local cmds = collect({}, sink)   -- clean inventory, but near water
    local r = Assert.notNil(find(cmds, "Wash Yourself"), "near water you can always Wash Yourself")
    restore()
    return r
end

tests["dirty_item_yields_wash_all_and_per_item"] = function()
    local sink, restore = washWorld()
    local cmds = collect({ clothing("Jeans", 0.6, 0), clothing("T-Shirt", 0, 0.3) }, sink)
    local okAll  = find(cmds, "Wash All")
    local okItem = find(cmds, "Wash Jeans")
    restore()
    if not Assert.notNil(okAll, "Wash All present with dirty items") then return false end
    if not Assert.equal(okAll.wsTier, 0, "Wash All is the default (tier 0)") then return false end
    return Assert.notNil(okItem, "a per-item Wash row exists")
end

tests["clean_inventory_only_wash_yourself"] = function()
    local sink, restore = washWorld()
    local cmds = collect({ clothing("Jeans", 0, 0) }, sink)   -- not dirty
    local r = (find(cmds, "Wash All") == nil) and (find(cmds, "Wash Yourself") ~= nil)
    restore()
    return Assert.isTrue(r, "clean clothes -> no Wash All, just Wash Yourself")
end

tests["rows_highlight_source_and_are_wash_category"] = function()
    local sink, restore = washWorld()
    local row = find(collect({ clothing("Jeans", 0.5, 0) }, sink), "Wash All")
    local r = row and row.hl == sink and row.category == "wash"
    restore()
    return Assert.isTrue(r, "wash rows outline the source and carry the wash category")
end

tests["wash_all_replays_the_handler"] = function()
    local sink, restore, calls = washWorld()
    find(collect({ clothing("Jeans", 0.7, 0) }, sink), "Wash All").run()
    local r = calls.wash == 1
    restore()
    return Assert.isTrue(r, "running Wash All calls onWashClothing once")
end

return tests
