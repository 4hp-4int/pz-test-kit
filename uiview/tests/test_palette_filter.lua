--[[
    UIView — pal_filter (the Filter engine, Phase B extraction)
    ===========================================================
    Direct unit tests of the palette's BRAIN with a plain command list and a fake
    `self` — no panel, no render. Before the refactor this logic was only
    reachable through a rendered frame. Covers: runnable-beats-blocked, query
    relevance order, zero-state pin/context tagging, and the noun/verb pivot.
]]

local Assert = PZTestKit.Assert
local SP = require "palette/pal_filter"

local function mkSelf(cmds, ctx)
    return {
        allCommands = cmds,
        contextFullType = ctx and ctx.fullType or nil,
        contextSquare   = ctx and ctx.square or nil,
        playerNum = 0,
    }
end

local function run(cmds, q, ctx)
    local s = mkSelf(cmds, ctx)
    SP.Filter.run(s, q or "")
    return s
end

local tests = {}

tests["matches_are_filtered_in"] = function()
    local s = run({ { label = "Open Box", category = "craft", runnable = true },
                    { label = "Drink Water", category = "drink", runnable = true } }, "open")
    return Assert.equal(#s.filtered, 1, "only the matching command survives the query")
end

tests["runnable_beats_blocked"] = function()
    -- same label/score; the runnable one must sort above the greyed one.
    local s = run({
        { label = "Open Box", category = "craft", runnable = false },
        { label = "Open Box", category = "craft", runnable = true },
    }, "open box")
    return Assert.isTrue(s.filtered[1].runnable == true, "+5000 runnable gap floats the doable row")
end

tests["earlier_substring_ranks_first"] = function()
    local s = run({
        { label = "Box Opener", category = "use", runnable = true },   -- "open" at pos 5
        { label = "Open Box",   category = "use", runnable = true },   -- "open" at pos 1
    }, "open")
    return Assert.equal(s.filtered[1].label, "Open Box", "earlier substring hit ranks first")
end

tests["no_match_excluded"] = function()
    local s = run({ { label = "Drink Water", category = "drink", runnable = true } }, "zzzzz")
    return Assert.equal(#s.filtered, 0, "a non-matching query filters everything out")
end

-- ── zero-state tagging ──────────────────────────────────────────────────────
tests["pinned_floats_and_tags_in_zero_state"] = function()
    _G.SaucePalette.Pins = { isPinned = function(c) return c._pinned == true end }
    local s = run({
        { label = "Plain", category = "use", runnable = true },
        { label = "Fave",  category = "use", runnable = true, _pinned = true },
    }, "")   -- zero-state
    _G.SaucePalette.Pins = nil
    if not Assert.equal(s.filtered[1].label, "Fave", "pinned row floats to the top in zero-state") then return false end
    return Assert.equal(s.filtered[1]._tag, "pinned", "pinned row carries the 'pinned' why-tag")
end

tests["context_selected_item_tagged"] = function()
    local axe = { label = "Equip Axe", category = "equip", runnable = true,
                  item = { getFullType = function() return "Base.Axe" end } }
    local s = run({ axe, { label = "Other", category = "use", runnable = true } },
                  "", { fullType = "Base.Axe" })
    return Assert.equal(axe._tag, "selected", "the looked-at item's verbs are tagged 'selected'")
end

tests["context_here_square_tagged"] = function()
    local door = { label = "Open Door", category = "world", runnable = true, sx = 1, sy = 2, sz = 0 }
    local s = run({ door }, "", { square = { 1, 2, 0 } })
    return Assert.equal(door._tag, "here", "a verb on the looked-at tile is tagged 'here'")
end

tests["spotted_forage_floats_and_tags"] = function()
    -- a "foragegrab" command (only emitted while search mode is on, for a seen item
    -- within reach) floats to the top in zero-state and carries the 'spotted' tag.
    local grab = { label = "Forage Mulberries", category = "forage", kind = "foragegrab", runnable = true }
    local s = run({
        { label = "Plain", category = "use", runnable = true },
        grab,
    }, "")   -- zero-state
    if not Assert.equal(s.filtered[1].label, "Forage Mulberries", "the spotted forage row floats to the top") then return false end
    return Assert.equal(grab._tag, "spotted", "it carries the 'spotted' why-tag")
end

tests["spotted_forage_untagged_while_typing"] = function()
    local grab = { label = "Forage Mulberries", category = "forage", kind = "foragegrab", runnable = true }
    local s = run({ grab }, "forage")
    return Assert.isNil(grab._tag, "a typed query is pure relevance — no spotted tag")
end

tests["severity_orders_siblings_in_zero_state"] = function()
    -- two med treatments on the same part: the higher-severity one (remove glass) must
    -- sort above the palliative one (bandage), not by alphabetical label.
    local s = run({
        { label = "Bandage - Left Arm", category = "med", runnable = true, severity = 200 },
        { label = "Remove Glass - Left Arm", category = "med", runnable = true, severity = 600 },
    }, "")   -- zero-state
    return Assert.equal(s.filtered[1].label, "Remove Glass - Left Arm",
        "higher severity sorts first (urgency over alphabetical)")
end

tests["severity_is_zero_state_only"] = function()
    -- a typed query is pure relevance — severity must not pull a non-match in
    local s = run({
        { label = "Bandage", category = "med", runnable = true, severity = 200 },
        { label = "Remove Glass", category = "med", runnable = true, severity = 600 },
    }, "bandage")
    return Assert.equal(#s.filtered, 1, "only the matching row survives; severity doesn't override the query")
end

tests["no_tags_while_typing"] = function()
    _G.SaucePalette.Pins = { isPinned = function() return true end }
    local s = run({ { label = "Open Box", category = "craft", runnable = true } }, "open")
    _G.SaucePalette.Pins = nil
    return Assert.isNil(s.filtered[1]._tag, "a typed query is pure relevance — no zero-state tags")
end

tests["minor_verbs_hidden_unless_their_own_label_is_typed"] = function()
    -- the minor verb's source is the WATER bottle; "water" is a synonym of "drink", so
    -- without the label-only rule, typing "drink" would sweep the Equip verb in too.
    local cmds = {
        { label = "Drink", category = "drink", runnable = true, source = "Water (Plastic Bottle)" },
        { label = "Equip Primary", category = "equip", runnable = true, minor = true, source = "Water (Plastic Bottle)" },
    }
    -- zero-state: minor hidden
    local s = run(cmds, "")
    local seen = {}; for _, c in ipairs(s.filtered) do seen[c.label] = true end
    if not Assert.isTrue(seen["Drink"] and not seen["Equip Primary"], "zero-state hides the minor equip verb, keeps Drink") then return false end
    -- typing "drink": the Equip verb must NOT be swept in by the water->drink synonym
    local sD = run(cmds, "drink")
    local sawEquip = false; for _, c in ipairs(sD.filtered) do if c.label == "Equip Primary" then sawEquip = true end end
    if not Assert.isFalse(sawEquip, "typing 'drink' does NOT pull in the minor Equip via a sibling synonym") then return false end
    -- typing "equip": the minor verb surfaces on its own label
    local sE = run(cmds, "equip")
    local sawE = false; for _, c in ipairs(sE.filtered) do if c.label == "Equip Primary" then sawE = true end end
    return Assert.isTrue(sawE, "typing 'equip' surfaces the minor verb (direct label match)")
end

tests["loot_outranks_general_categories_in_zero_state"] = function()
    -- a loot row exists only when a stocked container is in reach, so when present it
    -- floats above the general categories (use/open/craft/...) — but stays below
    -- survival needs (drink/eat/med).
    local s = run({
        { label = "Open Box",    category = "craft", runnable = true },
        { label = "Loot Fridge", category = "loot",  runnable = true },
        { label = "Drink Water", category = "drink", runnable = true },
    }, "")   -- zero-state
    if not Assert.equal(s.filtered[1].label, "Drink Water", "a survival need still ranks above loot") then return false end
    return Assert.equal(s.filtered[2].label, "Loot Fridge", "loot ranks above general craft when available")
end

-- ── noun / verb pivot ───────────────────────────────────────────────────────
tests["noun_pivot_on_item_name"] = function()
    -- "nails" hits the craft input (noun) but not the verb label -> noun pivot.
    local s = run({ { label = "Open Box", source = "craft", category = "craft",
                      runnable = true, inputName = "Box of Nails" } }, "nails")
    return Assert.equal(s._pivot, "noun", "matching the item name pivots noun-first")
end

tests["verb_pivot_on_label"] = function()
    local s = run({ { label = "Open Box", source = "Box of Nails", category = "craft",
                      runnable = true, inputName = "Box of Nails" } }, "open")
    return Assert.equal(s._pivot, "verb", "matching the verb label keeps the verb pivot")
end

-- ── incremental narrowing (perf) ────────────────────────────────────────────
tests["narrowing_scans_only_previous_matches"] = function()
    local cmds = {}
    for i = 1, 200 do cmds[i] = { label = "Widget " .. i, category = "use", runnable = true } end
    for _, l in ipairs({ "Open Box", "Cook Food", "Loot Crate", "Drop Log" }) do  -- contain 'o'
        cmds[#cmds + 1] = { label = l, category = "use", runnable = true }
    end
    local s = mkSelf(cmds)
    SP.Filter.run(s, "o")
    local cold, oMatches = SP.Filter._lastScan, #s.filtered
    SP.Filter.run(s, "op")   -- extends "o"
    local narrowed = SP.Filter._lastScan
    if not Assert.equal(cold, #cmds, "the first char scans the whole universe") then return false end
    return Assert.equal(narrowed, oMatches,
        "extending the query re-scans ONLY the previous matches, not all " .. #cmds)
end

tests["narrowing_result_equals_full_scan"] = function()
    local make = function() return {
        { label = "Open Box",  category = "craft", runnable = true },
        { label = "Open Door", category = "world", runnable = true },
        { label = "Close Box", category = "world", runnable = true },
    } end
    local s1 = mkSelf(make()); SP.Filter.run(s1, "open"); SP.Filter.run(s1, "open b")  -- narrowed path
    local s2 = mkSelf(make()); SP.Filter.run(s2, "open b")                              -- cold path
    if not Assert.equal(#s1.filtered, #s2.filtered, "narrowed + cold yield the same match count") then return false end
    for i = 1, #s2.filtered do
        if s1.filtered[i].label ~= s2.filtered[i].label then
            return Assert.isTrue(false, "narrowed result diverges from full scan at row " .. i)
        end
    end
    return Assert.isTrue(true, "narrowed path is identical to a full scan (set + order)")
end

tests["backspace_falls_back_to_full_scan"] = function()
    local cmds = { { label = "Open Box", category = "craft", runnable = true },
                   { label = "Apple",    category = "eat",   runnable = true } }
    local s = mkSelf(cmds)
    SP.Filter.run(s, "open")          -- narrows to 1 next time
    SP.Filter.run(s, "ope")           -- SHORTER (backspace) -> not an extension
    return Assert.equal(SP.Filter._lastScan, #cmds, "a backspace re-scans the full universe (no stale narrowing)")
end

return tests
