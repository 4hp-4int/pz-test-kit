--[[
    UIView — pal_cleaning (scrub blood/graffiti off tiles)
    ======================================================
    Drives the real cleaning collect() against a stubbed world: the centre square may
    carry blood (haveStains) and/or graffiti (haveGraffiti), and the can*/do* handlers
    are stubbed. Asserts: a bloody tile -> Clean Blood (runnable only with supplies,
    greyed otherwise); a graffiti tile -> Clean Graffiti; rows are the clean category;
    run replays do*; a clean tile -> nothing.
]]

local Assert = PZTestKit.Assert
local SP = require "palette/pal_cleaning"

local spy = { blood = 0, graffiti = 0 }
local function collect(opts)
    opts = opts or {}
    spy.blood, spy.graffiti = 0, 0
    _G.ISTimedActionQueue = _G.ISTimedActionQueue or {}
    _G.ISWorldObjectContextMenu = {
        canCleanBlood    = function() return opts.canBlood == true end,
        canCleanGraffiti = function() return opts.canGraffiti == true end,
        doCleanBlood     = function() spy.blood = spy.blood + 1 end,
        doCleanGraffiti  = function() spy.graffiti = spy.graffiti + 1 end,
    }
    local sq = { getX = function() return 0 end, getY = function() return 0 end, getZ = function() return 0 end,
                 haveStains = function() return opts.blood == true end,
                 haveGraffiti = function() return opts.graffiti == true end }
    _G.getCell = function() return { getGridSquare = function(_, x, y) if x == 0 and y == 0 then return sq end end } end
    local p = { _type = "IsoPlayer", getCurrentSquare = function() return sq end }
    _G._pz_player = p
    for _, s in ipairs(SP.sources) do if s.id == "cleaning" then return s.collect(0) end end
end

local function find(cmds, sub) for _, c in ipairs(cmds) do if tostring(c.label):find(sub, 1, true) then return c end end end

local tests = {}

tests["bloody_tile_offers_clean_blood"] = function()
    local row = find(collect({ blood = true, canBlood = true }), "Clean Blood")
    if not Assert.notNil(row, "blood + supplies -> Clean Blood") then return false end
    if not Assert.isTrue(row.runnable == true, "runnable with supplies") then return false end
    if not Assert.notNil(row.hl, "highlights the tile being scrubbed (no cursor opens)") then return false end
    return Assert.equal(row.category, "clean", "clean category")
end

tests["blood_blocked_without_supplies"] = function()
    local row = find(collect({ blood = true, canBlood = false }), "Clean Blood")
    if not Assert.notNil(row, "still shown so you know it's possible") then return false end
    if not Assert.isTrue(row.runnable == false, "no bleach/mop -> blocked") then return false end
    return Assert.notNil(row.blockReason, "with a reason")
end

tests["graffiti_tile_offers_clean_graffiti"] = function()
    local row = find(collect({ graffiti = true, canGraffiti = true }), "Clean Graffiti")
    return Assert.isTrue(row ~= nil and row.runnable == true, "graffiti + solvent -> Clean Graffiti")
end

tests["run_replays_the_clean_handler"] = function()
    find(collect({ blood = true, canBlood = true }), "Clean Blood").run()
    return Assert.equal(spy.blood, 1, "running Clean Blood calls doCleanBlood once")
end

tests["clean_tile_no_rows"] = function()
    return Assert.equal(#collect({ canBlood = true, canGraffiti = true }), 0, "no stains -> no rows")
end

return tests
