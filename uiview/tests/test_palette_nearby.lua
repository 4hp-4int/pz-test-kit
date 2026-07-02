--[[ pal_nearby — the NEARBY tier: room-scoped world verbs beyond the 3x3, far-tagged
     shallow copies (cache never mutated), capped, deduped against the immediate tier,
     kept warm by the room-aware eviction. Plus the filter's in-reach-first tie-break. ]]
local Assert = PZTestKit.Assert
require "palette/pal_nearby"
require "palette/pal_filter"
local SP = _G.SaucePalette
local N = SP.Nearby
local W = SP.World

-- same jlist/object mocks as the world tests, plus a ROOM: squares registered on the
-- room get getRoom()/getRoomID() answering it, and room:getSquares() lists them.
local function jlist(t) return { size = function() return #t end, get = function(_, i) return t[i + 1] end } end
local function mkObj(name)
    return { _type = "IsoObject", _name = name, getSprite = function() return nil end }
end

local function harness()
    local grid, calls = {}, 0
    local room = { _id = 7, _squares = {} }
    room.getSquares = function() return jlist(room._squares) end
    local function square(x, y, opts)
        local key = x .. "," .. y
        if not grid[key] then
            local objs = {}
            local sq = { _type = "IsoGridSquare", _objs = objs, _inRoom = false,
                getX = function() return x end, getY = function() return y end,
                getZ = function() return (opts and opts.z) or 0 end,
                getObjects = function() return jlist(objs) end }
            sq.getRoom = function() return sq._inRoom and room or nil end
            sq.getRoomID = function() return sq._inRoom and room._id or -1 end
            grid[key] = sq
        end
        return grid[key]
    end
    local center = square(0, 0)
    local saved = { cell = _G.getCell, menu = _G.ISWorldObjectContextMenu, ui = _G.UIManager,
                    msp = _G.ISMoveableSpriteProps, gsp = _G.getSpecificPlayer }
    _G.getCell = function() return { getGridSquare = function(_, x, y, z) if z ~= 0 then return nil end return square(x, y) end } end
    _G.ISWorldObjectContextMenu = { createMenu = function(_, objs)
        calls = calls + 1
        local opts = {}
        for _, o in ipairs(objs) do opts[#opts + 1] = { name = "Use " .. o._name, onSelect = function() end, target = o } end
        return { options = opts, getSubMenu = function() return nil end,
                 setVisible = function() end, hideAndChildren = function() end }
    end }
    _G.UIManager = { getSpeedControls = function() return { getCurrentGameSpeed = function() return 1 end } end }
    _G.ISMoveableSpriteProps = { fromObject = function(o) return { name = o and o._name } end }
    _G.getSpecificPlayer = function() return { _type = "IsoPlayer", getCurrentSquare = function() return center end } end
    W.invalidate()
    return {
        addRoomSq = function(x, y, name, opts)
            local sq = square(x, y, opts)
            sq._inRoom = true
            if name then table.insert(sq._objs, mkObj(name)) end
            table.insert(room._squares, sq)
            return sq
        end,
        joinRoom = function(x, y)   -- put an (already-created) square in the room
            local sq = square(x, y); sq._inRoom = true; table.insert(room._squares, sq); return sq
        end,
        addObj  = function(x, y, name) table.insert(square(x, y)._objs, mkObj(name)) end,
        moveTo  = function(x, y) center = square(x, y) end,
        calls   = function() return calls end,
        resetCalls = function() calls = 0 end,
        restore = function()
            _G.getCell, _G.ISWorldObjectContextMenu, _G.UIManager = saved.cell, saved.menu, saved.ui
            _G.ISMoveableSpriteProps, _G.getSpecificPlayer = saved.msp, saved.gsp
        end,
    }
end

local tests = {}

tests["harvests_room_beyond_3x3_with_far_dist"] = function()
    local h = harness()
    h.joinRoom(0, 0)                      -- player's square is in the room
    h.addRoomSq(4, 0, "Fridge")           -- far: dist 4
    h.addRoomSq(1, 1, "NearThing")        -- inside the 3x3: NOT this source's job
    h.addRoomSq(0, 6, "Shelf")            -- far: dist 6
    local cmds = N.collect(0)
    h.restore()
    if not Assert.equal(#cmds, 2, "only the beyond-3x3 room squares harvest") then return false end
    local byName = {}
    for _, c in ipairs(cmds) do byName[c.source or c.label] = c end
    local fridge = byName["Fridge"] or byName["Use Fridge"]
    if not Assert.notNil(fridge, "the far fridge is offered") then return false end
    return Assert.equal(fridge.far.dist, 4, "chebyshev distance rides on the row")
end

tests["outdoors_returns_nothing"] = function()
    local h = harness()
    h.addObj(5, 0, "Dumpster")            -- exists, but the player square has no room
    local cmds = N.collect(0)
    h.restore()
    return Assert.equal(#cmds, 0, "v1 is rooms only")
end

tests["other_floor_skipped"] = function()
    local h = harness()
    h.joinRoom(0, 0)
    h.addRoomSq(5, 0, "Upstairs", { z = 1 })
    local cmds = N.collect(0)
    h.restore()
    return Assert.equal(#cmds, 0, "same-floor squares only")
end

tests["cap_bounds_the_harvest"] = function()
    local h = harness()
    h.joinRoom(0, 0)
    for i = 1, N.MAX + 5 do h.addRoomSq(2 + i, 0, "Crate" .. i) end
    local cmds = N.collect(0)
    h.restore()
    return Assert.equal(#cmds, N.MAX, "object squares beyond N.MAX are truncated (and logged)")
end

tests["dedups_against_the_immediate_tier"] = function()
    local h = harness()
    h.joinRoom(0, 0)
    h.addObj(1, 0, "Fridge")              -- in reach, harvested by pal_world
    h.addRoomSq(5, 0, "Fridge")           -- same verb+noun far away
    W.collect(0)                          -- immediate tier first (warm cache = seen keys)
    local cmds = N.collect(0)
    h.restore()
    return Assert.equal(#cmds, 0, "a verb+noun already in reach isn't re-offered as a walk")
end

tests["cached_rows_are_never_far_mutated"] = function()
    local h = harness()
    h.joinRoom(0, 0)
    h.addRoomSq(5, 0, "Fridge")
    local cmds = N.collect(0)
    h.restore()
    if not Assert.notNil(cmds[1] and cmds[1].far, "returned row is far-tagged") then return false end
    local e = W._sqCache["5,0,0"]
    if not Assert.notNil(e, "square cached") then return false end
    return Assert.isNil(e.cmds[1].far, "the CACHED row carries no far tag (walk there -> it's served as near)")
end

tests["room_squares_survive_worldcollect_eviction"] = function()
    local h = harness()
    h.joinRoom(0, 0)
    h.addRoomSq(6, 0, "Fridge")           -- beyond chebyshev 2 of the player
    N.collect(0)                          -- caches the far square (roomId stamped)
    if not W._sqCache["6,0,0"] then h.restore(); return Assert.isTrue(false, "far square cached") end
    W.collect(0)                          -- immediate tier's eviction sweep runs here
    local kept = W._sqCache["6,0,0"] ~= nil
    h.restore()
    return Assert.isTrue(kept, "same-room squares outlive the radius-2 eviction")
end

tests["warm_nearby_recollect_does_no_new_harvest"] = function()
    local h = harness()
    h.joinRoom(0, 0)
    h.addRoomSq(4, 0, "Fridge"); h.addRoomSq(0, 5, "Shelf")
    N.collect(0)
    h.resetCalls()
    local cmds = N.collect(0)
    local n = h.calls()
    h.restore()
    if not Assert.equal(n, 0, "second collect is a full per-square cache hit") then return false end
    return Assert.equal(#cmds, 2, "cached rows still served (far-tagged copies)")
end

-- ── filter: in-reach beats far at equal footing (tie-break, not haircut) ─────
local function cmd(label, far)
    local c = { label = label, category = "world", kind = "world", runnable = true, run = function() end }
    if far then c.far = { dist = far } end
    return c
end

tests["filter_prefers_in_reach_on_equal_match"] = function()
    local near, far = cmd("Open Fridge"), cmd("Open Fridge", 6)
    local s = { allCommands = { far, near }, playerNum = 0 }
    SP.Filter.run(s, "fridge")
    if not Assert.isNil(s.filtered[1].far, "query: near first on an equal match") then return false end
    SP.Filter.run(s, "")
    return Assert.isNil(s.filtered[1].far, "zero-state: near first within the category")
end

tests["filter_better_far_match_still_wins"] = function()
    local nearWeak = cmd("Fully Random Interaction Dregs")   -- weak scatter for "fridge"? no match at all
    local farGood  = cmd("Open Fridge", 6)
    local s = { allCommands = { nearWeak, farGood }, playerNum = 0 }
    SP.Filter.run(s, "fridge")
    if not Assert.equal(#s.filtered, 1, "only the real match survives") then return false end
    return Assert.notNil(s.filtered[1].far, "a good far match isn't buried by distance")
end

return tests
