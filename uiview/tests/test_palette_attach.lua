--[[
    UIView — pal_attach (collapse hotbar attach slots under "Attach <item>")
    ========================================================================
    The attach options already arrive via the inventory harvest (onSelect =
    ISHotbar.attachItem) — flat, one row per slot. This adapter groups them. We stub
    ISHotbar, build harvested-style attach rows, and assert: pal_harvest tags them
    category="attach"; the family collapses every slot of one item under "Attach
    <item>" with the slots as the flavor; two different items make two families.
]]

local Assert = PZTestKit.Assert
local SP = require "palette/pal_attach"     -- registers the family
require "palette/pal_harvest"               -- SP.classifyAction
local Families = SP.Families

-- stub the hotbar with the two handler identities the classifier/adapter key on.
_G.ISHotbar = _G.ISHotbar or {}
_G.ISHotbar.attachItem = _G.ISHotbar.attachItem or function() end
_G.ISHotbar.removeItem = _G.ISHotbar.removeItem or function() end

local function weapon(name, ft)
    return { _type = "InventoryItem", getName = function() return name end, getFullType = function() return ft end }
end

-- a harvested-style attach row: onSelect = the hotbar attach, label = the slot name,
-- params[3] = the hotbar slot index (as the real harvest records it).
local function attachRow(item, slot, slotIndex)
    return { onSelect = _G.ISHotbar.attachItem, item = item, label = slot,
             kind = "action", category = "attach", source = item:getName(),
             params = { item, slot, slotIndex } }
end

local function find(cmds, sub)
    for _, c in ipairs(cmds) do if tostring(c.familyLabel or c.label):find(sub, 1, true) then return c end end
    return nil
end

local tests = {}

tests["classifier_tags_attach"] = function()
    if not Assert.equal(SP.classifyAction(_G.ISHotbar.attachItem, "Holster"), "attach",
        "an attachItem row is the attach category") then return false end
    return Assert.equal(SP.classifyAction(_G.ISHotbar.removeItem, "Remove"), "attach",
        "a removeItem row is the attach category too")
end

tests["slots_collapse_under_one_item"] = function()
    local pistol = weapon("Pistol", "Base.Pistol")
    local cmds = { attachRow(pistol, "Holster"), attachRow(pistol, "Back") }
    Families.apply(cmds)
    if not Assert.notNil(cmds[1].familyKey, "attach rows are stamped into a family") then return false end
    if not Assert.equal(cmds[1].familyKey, cmds[2].familyKey, "both slots share one family") then return false end
    return Assert.equal(cmds[1].familyLabel, "Attach Pistol", "head reads Attach <item>")
end

tests["flavor_lists_the_slots"] = function()
    local pistol = weapon("Pistol", "Base.Pistol")
    local cmds = { attachRow(pistol, "Holster"), attachRow(pistol, "Back") }
    Families.apply(cmds)
    local flav = cmds[1].familyFlavor or ""
    if not Assert.notNil(flav:find("Holster", 1, true), "flavor names the Holster slot") then return false end
    return Assert.notNil(flav:find("Back", 1, true), "flavor names the Back slot")
end

tests["distinct_items_distinct_families"] = function()
    local pistol = weapon("Pistol", "Base.Pistol")
    local rifle  = weapon("Rifle", "Base.Rifle")
    -- each item needs >=2 slots to actually form a family
    local cmds = { attachRow(pistol, "Holster", 2), attachRow(pistol, "Belt", 3),
                   attachRow(rifle, "Back", 1), attachRow(rifle, "Sling", 4) }
    Families.apply(cmds)
    return Assert.isTrue(cmds[1].familyKey ~= cmds[3].familyKey, "two items -> two distinct attach families")
end

tests["default_follows_hotbar_slot_order_not_alphabetical"] = function()
    -- a holster (slot index 2) sorts before back (index 5), even though "Back" < "Holster"
    local pistol = weapon("Pistol", "Base.Pistol")
    local cmds = { attachRow(pistol, "Holster", 2), attachRow(pistol, "Underbelt", 5) }
    Families.apply(cmds)
    local def
    for _, c in ipairs(cmds) do if c.familyDefault then def = c end end
    if not Assert.notNil(def, "a default slot was chosen") then return false end
    return Assert.equal(def.label, "Holster", "the lower slot index is the default, not the A-Z first")
end

tests["non_attach_rows_ignored"] = function()
    local pistol = weapon("Pistol", "Base.Pistol")
    local other = { onSelect = function() end, item = pistol, label = "Drop", kind = "action" }
    Families.apply({ other })
    return Assert.isTrue(other.familyKey == nil, "a non-attach row isn't pulled into the attach family")
end

return tests
