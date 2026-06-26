--[[ pal_world.nounFor — names the IsoObject a world verb acts on, scanning the
     harvested option's target then param1..10 for a real IsoObject and resolving
     its friendly moveable name. Locks: target wins, params are a fallback, the
     generic "Moveable object" placeholder is rejected, and the player is skipped. ]]
local Assert = PZTestKit.Assert
require "palette/pal_world"
require "palette/pal_harvest"   -- SP.Harvest.flatten (used by W.collect)
require "palette/pal_main"      -- SP.afterRun (post-action invalidation gating)
local W = _G.SaucePalette.World
local SP = _G.SaucePalette

-- harness instanceof = exact _type match; stub the moveable-name lookup to echo
-- each fake object's _name.
local function withMSP(fn)
    local saved = _G.ISMoveableSpriteProps
    _G.ISMoveableSpriteProps = { fromObject = function(o) return { name = o and o._name } end }
    local ok, err = pcall(fn)
    _G.ISMoveableSpriteProps = saved
    if not ok then error(err) end
end

local function obj(name) return { _type = "IsoObject", _name = name } end

local tests = {}

tests["noun_from_target"] = function()
    local res
    withMSP(function() res = W.nounFor({ target = obj("Chrome Oven"), params = {} }) end)
    return Assert.equal(res, "Chrome Oven", "noun resolved from the target IsoObject")
end

tests["noun_from_params_when_target_generic"] = function()
    -- light switch: target is the worldobjects table / a generic object; the real
    -- object is in param1.
    local res
    withMSP(function()
        res = W.nounFor({ target = obj("Moveable object"), params = { obj("Light Switch") } })
    end)
    return Assert.equal(res, "Light Switch", "falls through generic target to the param object")
end

tests["noun_nil_when_only_generic"] = function()
    local res
    withMSP(function() res = W.nounFor({ target = obj("Moveable object"), params = {} }) end)
    return Assert.isNil(res, "generic placeholder rejected -> no noun")
end

tests["noun_skips_player_and_primitives"] = function()
    -- target is the player (IsoGameCharacter), params hold a number/string then
    -- the real object — must skip non-objects and the character.
    local res
    withMSP(function()
        res = W.nounFor({ target = { _type = "IsoGameCharacter", _name = "Bob" },
                          params = { 0, "nearby", obj("Generator") } })
    end)
    return Assert.equal(res, "Generator", "skips player + primitives, names the generator")
end

-- ── W.collect per-square cache ──────────────────────────────────────────────
-- a live sized list over an array (count reflects pushes immediately).
local function jlist(t) return { size = function() return #t end, get = function(_, i) return t[i + 1] end } end
local function mkObj(name, sprite)
    return { _type = "IsoObject", _name = name,
             getSprite = function() if sprite then return { getName = function() return sprite end } end return nil end }
end

-- build a world harness: a create-on-demand grid, a counting createMenu stub, a
-- movable player, and the speed/noun stubs W.collect needs. Returns helpers + restore.
local function harness()
    local grid, calls = {}, 0
    local function square(x, y)
        local key = x .. "," .. y
        if not grid[key] then
            local objs = {}
            grid[key] = { _type = "IsoGridSquare", _objs = objs,
                getX = function() return x end, getY = function() return y end, getZ = function() return 0 end,
                getObjects = function() return jlist(objs) end }
        end
        return grid[key]
    end
    local center = square(0, 0)
    local saved = { cell = _G.getCell, menu = _G.ISWorldObjectContextMenu, ui = _G.UIManager,
                    msp = _G.ISMoveableSpriteProps, player = _G._pz_player }
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
    _G._pz_player = { _type = "IsoPlayer", getCurrentSquare = function() return center end }
    W.invalidate()
    return {
        addObj   = function(x, y, name, sprite) table.insert(square(x, y)._objs, mkObj(name or ("o" .. x .. y), sprite)) end,
        moveTo   = function(x, y) center = square(x, y) end,
        collect  = function() return W.collect(0) end,
        resetCalls = function() calls = 0 end,
        calls    = function() return calls end,
        restore  = function()
            _G.getCell, _G.ISWorldObjectContextMenu, _G.UIManager = saved.cell, saved.menu, saved.ui
            _G.ISMoveableSpriteProps, _G._pz_player = saved.msp, saved.player
        end,
    }
end

-- populate the player square + 8 neighbours (and optionally a step column) with one
-- object each, so every scanned square is non-empty (-> one createMenu when uncached).
local function fillWindow(h, cx, cy, extraColX)
    for dy = -1, 1 do for dx = -1, 1 do h.addObj(cx + dx, cy + dy, "t" .. (cx + dx) .. (cy + dy)) end end
    if extraColX then for dy = -1, 1 do h.addObj(extraColX, cy + dy, "t" .. extraColX .. (cy + dy)) end end
end

tests["second_collect_same_spot_is_a_full_cache_hit"] = function()
    local h = harness()
    fillWindow(h, 0, 0)
    h.collect()                       -- cold: harvests the 9 squares
    h.resetCalls()
    h.collect()                       -- warm: same spot
    local n = h.calls()
    h.restore()
    return Assert.equal(n, 0, "re-opening in place does ZERO createMenu calls")
end

tests["one_tile_step_reharvests_only_the_new_column"] = function()
    local h = harness()
    fillWindow(h, 0, 0, 2)            -- window at 0,0 + the column at x=2 for the step
    h.collect()                       -- cold at (0,0): columns -1,0,1
    h.resetCalls()
    h.moveTo(1, 0)                    -- step east: columns 0,1,2 — only x=2 is new
    h.collect()
    local n = h.calls()
    h.restore()
    return Assert.equal(n, 3, "an orthogonal step harvests exactly the 3 new squares")
end

tests["warm_output_identical_to_cold"] = function()
    local h = harness()
    fillWindow(h, 0, 0)
    W.invalidate(); local cold = h.collect()
    local warm = h.collect()
    h.restore()
    if not Assert.equal(#warm, #cold, "same number of rows warm vs cold") then return false end
    for i = 1, #cold do
        local a, b = cold[i], warm[i]
        if a.label ~= b.label or a.source ~= b.source or a.sx ~= b.sx or a.sy ~= b.sy then
            return Assert.isTrue(false, "row " .. i .. " differs warm vs cold")
        end
    end
    return Assert.isTrue(true, "warm output is element-by-element identical to cold")
end

tests["object_count_change_reharvests_that_square"] = function()
    local h = harness()
    fillWindow(h, 0, 0)
    h.collect()
    h.resetCalls()
    h.addObj(0, 0, "NewThing")        -- count on the centre square changes
    local cmds = h.collect()
    local n = h.calls()
    local found = false
    for _, c in ipairs(cmds) do if tostring(c.label):find("NewThing", 1, true) then found = true end end
    h.restore()
    if not Assert.equal(n, 1, "only the changed square re-harvests") then return false end
    return Assert.isTrue(found, "the new object's verb appears")
end

-- ── SP.afterRun: gate the per-square bust by command kind ───────────────────
local function seedCache() W._sqCache = { ["0,0,0"] = { stamp = 1, cmds = {}, x = 0, y = 0, z = 0 } } end
local function cacheEmpty() for _ in pairs(W._sqCache) do return false end return true end

tests["afterRun_keeps_cache_for_non_world_actions"] = function()
    if not Assert.notNil(SP.afterRun, "SP.afterRun exists") then return false end
    for _, k in ipairs({ "eat", "loot", "pickup", "equip", "craft", "fluid", "wash" }) do
        seedCache()
        SP.afterRun({ kind = k })
        if not Assert.isTrue(not cacheEmpty(), "'" .. k .. "' keeps the per-square cache") then return false end
    end
    return true
end

tests["afterRun_clears_cache_for_world_mutators"] = function()
    for _, k in ipairs({ "world", "cookable", "moveable" }) do
        seedCache()
        SP.afterRun({ kind = k })
        if not Assert.isTrue(cacheEmpty(), "'" .. k .. "' clears the per-square cache") then return false end
    end
    return true
end

-- ── decoration pre-filter (grass/blends never yield verbs) ──────────────────
tests["isDecor_matches_only_decoration"] = function()
    local function spr(s) return { getSprite = function() return { getName = function() return s end } end } end
    -- FILTERED — provably inert per ISDestroyCursor + the verb-gate audit
    for _, s in ipairs({
        "vegetation_groundcover_01_22", "blends_natural_01_5", "blends_grassoverlays_02_1",
        "blends_streetoverlays_01_0", "overlay_blood_floor_01_3", "overlay_grime_wall_01_2",
        "d_generic_01_8", "d_streetcracks_01_4", "d_trash_01_0", "street_trafficlines_01_2",
        "street_curbs_01_1", "e_newsnow_ground_01_0", "e_newgrass_1_5",
    }) do
        if not Assert.isTrue(W._isDecor(spr(s)), s .. " is decoration (filtered)") then return false end
    end
    -- KEPT — each can carry a verb; must NEVER be filtered
    for _, s in ipairs({
        "vegetation_trees_01_3",      -- a tree (IsoTree -> chop/forage)
        "vegetation_farm_01_0",       -- a crop (harvest)
        "floors_exterior_natural_01", -- a floor (take-dirt / sweep)
        "f_bushes_1_2",               -- foliage (may be a bush with a verb)
        "d_plants_01_3",              -- foraging-adjacent plant overlay
        "walls_exterior_house_01_8",  -- a wall (destroy/dismantle)
        "furniture_seating_indoor_01",-- furniture (pick up / disassemble)
    }) do
        if not Assert.isTrue(not W._isDecor(spr(s)), s .. " is NOT filtered (can have a verb)") then return false end
    end
    return Assert.isTrue(not W._isDecor({ getSprite = function() return nil end }), "no sprite -> not decoration")
end

tests["decoration_is_filtered_real_object_kept"] = function()
    local h = harness()
    h.addObj(0, 0, "Chrome Oven")                              -- real (no sprite -> kept)
    h.addObj(0, 0, "grass", "vegetation_groundcover_01_7")     -- decoration -> dropped
    local cmds = h.collect()
    local oven = false
    for _, c in ipairs(cmds) do if tostring(c.label):find("Chrome Oven", 1, true) then oven = true end end
    h.restore()
    if not Assert.isTrue(oven, "the real object's verb still appears") then return false end
    for _, c in ipairs(cmds) do
        if tostring(c.label):find("grass", 1, true) then return Assert.isTrue(false, "decoration must NOT produce a verb") end
    end
    return Assert.isTrue(true, "decoration produced no verb (filtered before createMenu)")
end

tests["all_decoration_square_skips_createMenu"] = function()
    local h = harness()
    -- the whole 3x3 is pure grass -> every square filters to empty -> no createMenu
    for dy = -1, 1 do for dx = -1, 1 do h.addObj(dx, dy, "grass", "vegetation_groundcover_01_3") end end
    h.collect()
    local n = h.calls()
    h.restore()
    return Assert.equal(n, 0, "an all-grass neighborhood makes ZERO createMenu calls")
end

tests["afterRun_nil_safe"] = function()
    seedCache()
    local ok = pcall(function() SP.afterRun(nil) end)
    return Assert.isTrue(ok, "afterRun(nil) doesn't error")
end

tests["invalidate_clears_the_cache"] = function()
    local h = harness()
    fillWindow(h, 0, 0)
    h.collect()
    W.invalidate()
    local empty = true
    for _ in pairs(W._sqCache) do empty = false; break end
    if not Assert.isTrue(empty, "invalidate empties the per-square cache") then h.restore(); return false end
    h.resetCalls()
    h.collect()                       -- must fully rebuild
    local n = h.calls()
    h.restore()
    return Assert.equal(n, 9, "after invalidate the next collect re-harvests all 9 squares")
end

return tests
