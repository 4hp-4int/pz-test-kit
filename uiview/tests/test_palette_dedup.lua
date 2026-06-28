--[[ SP.dedup — cross-source noise reducer. The moveables family owns an object's
     verbs; a harvested/world row that's the SAME verb on the SAME named object is
     dropped, so you don't see a standalone "Disassemble Chair" next to the family.
     Only non-moveable rows are ever removed. ]]
local Assert = PZTestKit.Assert
local SP = require "palette/pal_families"

local function mv(verb, name)
    return { label = verb .. " - " .. name, kind = "moveable", mvName = name }
end
local function world(label) return { label = label, kind = "world" } end

local tests = {}

tests["dedup_exists"] = function()
    return Assert.notNil(SP.dedup, "SP.dedup present")
end

tests["drops_harvested_dup_of_owned_object"] = function()
    local cmds = {
        mv("Pick Up", "Wooden Chair"), mv("Disassemble", "Wooden Chair"),
        world("Disassemble Wooden Chair"),   -- a furniture mod's world-menu row
        world("Board Up Window"),            -- unrelated, keep
    }
    local out = SP.dedup(cmds)
    local labels = {}
    for _, c in ipairs(out) do labels[c.label] = true end
    if not Assert.isNil(labels["Disassemble Wooden Chair"], "harvested dup of owned object dropped") then return false end
    if not Assert.isTrue(labels["Board Up Window"] == true, "unrelated world row kept") then return false end
    -- the family's own members survive
    return Assert.isTrue(labels["Pick Up - Wooden Chair"] == true and labels["Disassemble - Wooden Chair"] == true,
        "moveable family members never dropped")
end

tests["keeps_world_rows_for_unowned_objects"] = function()
    local cmds = {
        mv("Pick Up", "Lamp"),
        world("Pick Up Generator"),   -- "Generator" not owned -> keep
    }
    local out = SP.dedup(cmds)
    local found = false
    for _, c in ipairs(out) do if c.label == "Pick Up Generator" then found = true end end
    return Assert.isTrue(found, "world pickup of a non-owned object is kept")
end

tests["noop_when_no_moveables"] = function()
    local cmds = { world("Disassemble Chair"), world("Grab Apple") }
    local out = SP.dedup(cmds)
    return Assert.equal(#out, 2, "no moveables -> nothing owned -> nothing dropped")
end

return tests
