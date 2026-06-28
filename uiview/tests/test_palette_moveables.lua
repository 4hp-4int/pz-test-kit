--[[ pal_moveables — the "<Object>" family wiring for moveable verbs (Pick Up /
     Disassemble / Repair). collect() needs the live moveables API (no harness
     mock), but the family that collapses an object's verbs is pure data. ]]
local Assert = PZTestKit.Assert
local SP = require "palette/pal_moveables"
local Families = SP.Families

local function mvCmd(verb, name, runnable)
    return { label = verb .. " - " .. name, kind = "moveable", mvName = name,
             mvVerb = verb, runnable = runnable ~= false, source = name }
end

-- collect-driven coverage: fixture objects on a tile + a stubbed sprite-props.
local Fixtures = PZTestKit.Fixtures
local function moveableCollect()
    for _, s in ipairs(SP.sources) do if s.id == "moveable" then return s.collect end end
end
local function makeObject(o)
    local obj = { _type = o.itype or "IsoObject" }
    local sp = { name = o.name or "Chair", spriteName = "spr",
                 isMoveable = o.isMoveable ~= false, canScrap = o.canScrap or false,
                 pickUpTool = o.pickUpTool, material = o.material }
    sp.canPickUpMoveable = function(self, p, sq, ob) return o.canPickUp or false end
    sp.hasTool           = function(self, p, mode) return o.hasTool or nil end
    sp.hasRequiredSkill  = function(self, p, mode) return o.hasSkill end
    sp.canScrapObject    = function(self, p) return o.scrap end
    obj._sp = sp
    return obj
end
local function collectLive(objs)
    _G.ISMoveablesAction = _G.ISMoveablesAction or {}
    _G.ISMoveableSpriteProps = {
        fromObject = function(obj) return obj and obj._sp end,
        fromObjectForRepair = function(obj) return obj and obj._rp end,
    }
    local world = Fixtures.world()
    local center = world:square(5, 5, 0)
    for _, obj in ipairs(objs) do table.insert(center._private.objects, obj) end
    _G._pz_player = Fixtures.player({ square = center })
    return moveableCollect()(0)
end
local function find(cmds, sub)
    for _, c in ipairs(cmds) do if tostring(c.label):find(sub, 1, true) then return c end end
    return nil
end

local tests = {}

tests["source_and_family_present"] = function()
    if not Assert.notNil(SP.Moveables and SP.Moveables.collect, "moveable source collect exists") then return false end
    return Assert.notNil(Families and Families.apply, "Families.apply present")
end

tests["collapse_noun_head_verb_flavor"] = function()
    local cmds = {
        mvCmd("Pick Up",     "Wooden Chair"),
        mvCmd("Disassemble", "Wooden Chair"),
        mvCmd("Repair",      "Wooden Chair"),
    }
    Families.apply(cmds)
    local key
    for _, c in ipairs(cmds) do
        if not Assert.notNil(c.familyKey, "member stamped with familyKey") then return false end
        key = key or c.familyKey
        if not Assert.equal(c.familyKey, key, "all verbs share one family key") then return false end
    end
    -- head is the NOUN; verbs ride on the right as flavor (rank order)
    if not Assert.equal(cmds[1].familyLabel, "Wooden Chair", "head = noun") then return false end
    return Assert.equal(cmds[1].familyFlavor, "Pick Up, Disassemble, Repair", "verbs as flavor in rank order")
end

tests["blocked_verb_marked_available_first_and_default"] = function()
    -- Pick Up blocked, Disassemble available.
    local cmds = {
        mvCmd("Pick Up",     "Crate", false),
        mvCmd("Disassemble", "Crate", true),
    }
    Families.apply(cmds)
    if not Assert.equal(cmds[1].familyLabel, "Crate", "head = noun") then return false end
    if not Assert.equal(cmds[1].familyFlavor, "Disassemble, Pick Up*", "available first, blocked marked *") then return false end
    local def; for _, c in ipairs(cmds) do if c.familyDefault then def = c end end
    return Assert.equal(def and def.label, "Disassemble - Crate", "default (Enter) is the available verb")
end

tests["two_objects_two_families"] = function()
    local cmds = {
        mvCmd("Pick Up", "Chair"), mvCmd("Disassemble", "Chair"),
        mvCmd("Pick Up", "Lamp"),  mvCmd("Disassemble", "Lamp"),
    }
    Families.apply(cmds)
    local keys = {}
    for _, c in ipairs(cmds) do if c.familyKey then keys[c.familyKey] = true end end
    local n = 0; for _ in pairs(keys) do n = n + 1 end
    return Assert.equal(n, 2, "two objects -> two distinct families")
end

-- ── collect() driven (real source over fixture objects) ─────────────────────
tests["collect_pickup_runnable"] = function()
    local cmds = collectLive({ makeObject({ name = "Wooden Chair", canPickUp = true }) })
    local row = find(cmds, "Pick Up")
    return Assert.isTrue(row ~= nil and row.runnable == true, "canPickUpMoveable -> runnable Pick Up")
end

tests["collect_pickup_blocked_names_tool"] = function()
    local cmds = collectLive({ makeObject({
        name = "Oven", canPickUp = false, pickUpTool = "Base.Hammer", hasSkill = true }) })
    local row = find(cmds, "Pick Up")
    if not Assert.isTrue(row ~= nil and row.runnable == false, "no tool -> blocked") then return false end
    return Assert.notNil(tostring(row.blockReason):find("Hammer", 1, true), "reason names the missing tool")
end

tests["collect_disassemble_when_scrappable"] = function()
    local cmds = collectLive({ makeObject({ name = "Crate", canScrap = true, scrap = { canScrap = true } }) })
    local row = find(cmds, "Disassemble")
    return Assert.isTrue(row ~= nil and row.runnable == true, "canScrap -> runnable Disassemble")
end

tests["collect_non_moveable_nothing"] = function()
    local cmds = collectLive({ makeObject({ name = "Wall", isMoveable = false, canScrap = false }) })
    return Assert.equal(#cmds, 0, "non-moveable, non-scrappable -> nothing")
end

return tests
