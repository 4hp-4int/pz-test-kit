--[[
    UIView — pal_groups (the Grouping engine, Phase C extraction)
    =============================================================
    Direct unit tests of the grouping decision + build with a plain command list
    and a fake `self` — no panel. Covers the axis precedence (noun > family >
    craftname > verb), craft-name variant collapse, family build + flavor, row
    flatten, and urgent zero-state surfacing.
]]

local Assert = PZTestKit.Assert
local SP = require "palette/pal_groups"
local G = SP.Groups

local function build(cmds, pivot)
    local s = { filtered = cmds, _pivot = pivot or "verb", browse = false }
    G.build(s)
    return s
end

local tests = {}

-- ── the axis decision ───────────────────────────────────────────────────────
tests["verb_axis_is_default"] = function()
    local _, _, _, axis = G.keyFor({ label = "Eat Apple", category = "eat" }, "verb")
    return Assert.equal(axis, "verb", "a plain command keys by verb")
end

tests["craftname_collapses_variants"] = function()
    local _, label, _, axis = G.keyFor({ label = "Open Box (100 Items)", category = "craft" }, "verb")
    if not Assert.equal(axis, "craftname", "a craft with a variant suffix keys by craft-name") then return false end
    return Assert.equal(label, "Open Box", "the shared base phrase is the head label")
end

tests["family_axis_when_familyKey"] = function()
    local _, label, _, axis = G.keyFor(
        { label = "Pick Up - Chair", category = "world", familyKey = "obj:chair", familyLabel = "Chair" }, "verb")
    if not Assert.equal(axis, "family", "a familyKey'd command keys by family") then return false end
    return Assert.equal(label, "Chair", "family head label = the noun")
end

tests["noun_pivot_overrides_family"] = function()
    local _, _, _, axis = G.keyFor(
        { label = "Open Box", category = "craft", inputName = "Box of Nails", familyKey = "x" }, "noun")
    return Assert.equal(axis, "noun", "noun pivot pulls an item-anchored command into its item hub, over its family")
end

-- ── build ─────────────────────────────────────────────────────────────────
tests["craft_variants_collapse_to_one_group"] = function()
    local s = build({
        { label = "Open Box (100 Items)", category = "craft", runnable = true },
        { label = "Open Box (50 Items)",  category = "craft", runnable = true },
    })
    if not Assert.equal(#s.groups, 1, "two variants -> one collapsed group") then return false end
    return Assert.isTrue(s.groups[1].byName == true, "the group is marked byName")
end

tests["distinct_verbs_distinct_groups"] = function()
    local s = build({
        { label = "Eat Apple",   category = "eat",   runnable = true },
        { label = "Drink Water", category = "drink", runnable = true },
    })
    return Assert.equal(#s.groups, 2, "two distinct verbs -> two groups")
end

tests["family_members_one_group_with_flavor"] = function()
    local s = build({
        { label = "Pick Up - Chair", category = "world", runnable = true,
          familyKey = "obj:chair", familyLabel = "Chair", familyFlavor = "Pick Up, Disassemble" },
        { label = "Disassemble - Chair", category = "world", runnable = true,
          familyKey = "obj:chair", familyLabel = "Chair" },
    })
    if not Assert.equal(#s.groups, 1, "one family group for the object") then return false end
    if not Assert.isTrue(s.groups[1].isFamily == true, "marked isFamily") then return false end
    return Assert.equal(s.groups[1].flavor, "Pick Up, Disassemble", "the verb flavor rides on the head")
end

tests["single_member_emits_single_row"] = function()
    local s = build({ { label = "Solo Verb", category = "use", runnable = true } })
    return Assert.equal(s.rows[1].kind, "single", "a one-member group flattens to a single row")
end

tests["multi_member_group_row_collapsed"] = function()
    local s = build({
        { label = "Eat Apple", category = "eat", runnable = true },
        { label = "Eat Apple", category = "eat", runnable = true },
    })
    -- same label -> one verb group of 2; collapsed (not expanded) -> a "group" row only
    return Assert.equal(s.rows[1].kind, "group", "a multi-member group flattens to a collapsed group row")
end

tests["urgent_member_tags_and_expands_head"] = function()
    local s = build({
        { label = "Apply Bandage - Arm", category = "med", runnable = true,
          familyKey = "med:arm", familyLabel = "Arm", _tag = "bandage" },
        { label = "Disinfect - Arm", category = "med", runnable = true,
          familyKey = "med:arm", familyLabel = "Arm" },
    })
    local g = s.groups[1]
    if not Assert.equal(g._tag, "bandage", "the urgent member's reason surfaces on the head") then return false end
    return Assert.isTrue(g.expanded == true, "a multi-verb urgent group auto-expands for one-keystroke triage")
end

tests["only_top_urgent_group_auto_expands"] = function()
    -- two tagged multi-verb groups (e.g. a broad need touching many items): only the
    -- FIRST (most urgent) expands; the rest carry the tag but stay collapsed.
    local s = build({
        { label = "Place A", category = "place", runnable = true, familyKey = "a", familyLabel = "Item A", _tag = "overloaded" },
        { label = "Drop A",  category = "place", runnable = true, familyKey = "a", familyLabel = "Item A" },
        { label = "Place B", category = "place", runnable = true, familyKey = "b", familyLabel = "Item B", _tag = "overloaded" },
        { label = "Drop B",  category = "place", runnable = true, familyKey = "b", familyLabel = "Item B" },
    })
    local expandedCount = 0
    for _, g in ipairs(s.groups) do
        if g._tag then Assert.equal(g._tag, "overloaded", "tagged head keeps its reason") end
        if g.expanded then expandedCount = expandedCount + 1 end
    end
    return Assert.equal(expandedCount, 1, "exactly ONE urgent group auto-expands, not every tagged group")
end

tests["family_category_drives_the_head_chip"] = function()
    -- a heterogeneous item hub (drink + equip under one item) must wear the family's
    -- declared category (item), NOT whichever member created the group (drink).
    local _, _, category = G.keyFor(
        { label = "All", category = "drink", familyKey = "item:Base.OrangeJuice",
          familyLabel = "Orange Juice", familyCategory = "item" }, "verb")
    if not Assert.equal(category, "item", "familyCategory overrides the member category for the head") then return false end
    -- and a family WITHOUT a declared category still uses the member's
    local _, _, cat2 = G.keyFor(
        { label = "Take All", category = "loot", familyKey = "loot:1", familyLabel = "Loot Crate" }, "verb")
    return Assert.equal(cat2, "loot", "a family with no familyCategory keeps the member category")
end

return tests
