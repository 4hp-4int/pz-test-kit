--[[ pal_craft.craftN batch dispatch, via CraftMock. ONE path now: vanilla's
     ISEntityUI.HandcraftStartMultiple, which re-resolves the recipe's inputs per
     action. It handles distinct-item recipes (Rip Clothing: a different garment
     per craft, auto-resolved) AND multi-resource recipes (GoM "Pack Ammo in Box":
     box + ammo per craft) — the old per-item "distinct" path pinned one item and
     dropped a 2-input recipe's second resource ("Pack 5" packed only one). These
     tests lock: N actions queued, every action via the multi path, an HONEST
     return count (not 0 from a post-queue cleanup throw -> false "Couldn't"), and
     clamping to the craftable max. ]]
local Assert    = PZTestKit.Assert
local CraftMock = require "UIView/CraftMock"
local RecipeDB  = require "UIView/RecipeDB"
require "palette/pal_craft"
local SP = _G.SaucePalette

local function craftUnder(items, count, recipe, n, fn)
    CraftMock.craftCount = count
    CraftMock.install(items)
    local q = SP.Craft.craftN(0, recipe, n)
    local nq = #CraftMock.queue
    CraftMock.restore()
    return fn(q, nq)
end

local tests = {}

tests["distinct_items_batch_via_multi"] = function()
    -- 5 distinct boxes, craftable 5 (Rip-Clothing shape: a fresh item per craft).
    -- Auto-resolution in HandcraftStartMultiple picks a different item each time.
    local items = {}
    for _ = 1, 5 do items[#items + 1] = CraftMock.item("Base.Box") end
    return craftUnder(items, 5, CraftMock.recipe("OpenBox", "Base.Box"), 5, function(q, nq)
        if not Assert.equal(nq, 5, "5 actions queued (one per box)") then return false end
        for _, a in ipairs(CraftMock.queue) do
            if not Assert.equal(a.multi == true, true, "via HandcraftStartMultiple") then return false end
        end
        return Assert.equal(q, 5, "returns honest 5")
    end)
end

tests["fungible_batch_queues_n_and_returns_honest_count"] = function()
    -- 1 ammo pile, craftable 5. Was the "Pack 5 only did one" + "5 Open
    -- false-Couldn't" bug.
    return craftUnder({ CraftMock.item("Base.Ammo") }, 5, CraftMock.recipe("PackAmmo", "Base.Ammo"), 5,
        function(q, nq)
            if not Assert.equal(nq, 5, "5 actions queued (not 1)") then return false end
            return Assert.equal(q, 5, "returns 5 (honest, not 0 -> no false toast)")
        end)
end

tests["multi_input_recipe_resolves_both_inputs"] = function()
    -- GoM Pack = box + ammo (2 consumed inputs). HandcraftStartMultiple resolves
    -- BOTH inputs per craft. The old per-item distinct path pinned one box and
    -- dropped the ammo -> "Pack 5 packed only one". Every action is {multi}.
    local items = {}
    for _ = 1, 5 do items[#items + 1] = CraftMock.item("Base.Box") end
    items[#items + 1] = CraftMock.item("Base.Ammo")
    return craftUnder(items, 5, CraftMock.recipe("PackAmmo", "Base.Box", "Base.Ammo"), 5, function(q, nq)
        if not Assert.equal(nq, 5, "5 actions queued") then return false end
        for _, a in ipairs(CraftMock.queue) do
            if not Assert.equal(a.multi == true, true, "via HandcraftStartMultiple, not per-item") then return false end
        end
        return Assert.equal(q, 5, "returns honest 5")
    end)
end

tests["batch_clamps_to_craftable_count"] = function()
    -- ask for 10 but only 3 craftable -> 3
    local items = {}
    for _ = 1, 3 do items[#items + 1] = CraftMock.item("Base.Box") end
    return craftUnder(items, 3, CraftMock.recipe("OpenBox", "Base.Box"), 10, function(q, nq)
        return Assert.equal(nq, 3, "clamped to craftable count")
    end)
end

tests["collect_command_runN_returns_count"] = function()
    -- Regression: the craft command's runN closure must RETURN craftN's count.
    -- It once read `function(nn) C.craftN(...) end` (no return) -> runSel saw nil
    -- -> res collapsed to 0 -> "Couldn't" toast even though the batch queued fine
    -- ("it works now but the toast says couldnt"). Same class on `run` (single).
    SP.Craft._recipes = nil          -- bust the per-session recipe cache
    CraftMock.craftCount = 4
    RecipeDB.install()
    CraftMock.install({ CraftMock.item("Base.Log") })
    local cmds = SP.Craft.collect(0)
    local cmd
    for _, c in ipairs(cmds) do if c.runN then cmd = c; break end end
    local resN = cmd and cmd.runN(3)
    local resOne = cmd and cmd.run and cmd.run()
    CraftMock.restore(); RecipeDB.restore(); SP.Craft._recipes = nil
    if not Assert.notNil(cmd, "collect produced a batchable craft command") then return false end
    if not Assert.equal(type(resN), "number", "runN returns a number, not nil") then return false end
    if not Assert.equal(resN, 3, "runN returns the queued count (n clamped to maxN=4)") then return false end
    return Assert.notNil(resOne, "run (single) returns its result, not nil")
end

tests["unpack_recipe_splits_into_one_row_per_box"] = function()
    -- Regression: unpackCommands referenced a not-yet-defined `recipeName` local and
    -- crashed "Object tried to call nil" on any real packing recipe (no test exercised
    -- the path). It must run AND split the generic "Open Box" recipe into a row per box
    -- the player carries — distinct rows, pinned, not one ambiguous "(100 Items)".
    SP.Craft._recipes = nil; SP.Craft._unpack = nil
    RecipeDB.install()
    CraftMock.install({ CraftMock.item("Base.NailsBox"), CraftMock.item("Base.ScrewsBox") })
    local ok, cmds = pcall(SP.Craft.collect, 0)
    CraftMock.restore(); RecipeDB.restore(); SP.Craft._recipes = nil; SP.Craft._unpack = nil
    if not Assert.equal(ok, true, "collect runs the unpack path without error") then return false end
    local byBox = {}
    for _, c in ipairs(cmds or {}) do
        if c.inputType == "Base.NailsBox" or c.inputType == "Base.ScrewsBox" then byBox[c.inputType] = c end
    end
    if not Assert.notNil(byBox["Base.NailsBox"], "a row pinned to the nails box") then return false end
    if not Assert.notNil(byBox["Base.ScrewsBox"], "a row pinned to the screws box") then return false end
    if not Assert.equal(type(byBox["Base.NailsBox"].run), "function", "the box row is runnable") then return false end
    return Assert.equal(byBox["Base.NailsBox"] ~= byBox["Base.ScrewsBox"], true,
        "two distinct rows, not one ambiguous '(100 Items)'")
end

tests["near_miss_surfaces_when_you_hold_the_subject"] = function()
    -- Hold a Log but lack the saw: "Saw Log" should show as a blocked near-miss
    -- ("almost-possible"), so you see it without menu-diving.
    SP.Craft._recipes = nil
    RecipeDB.install()
    CraftMock.install({ CraftMock.item("Base.Log") }); CraftMock.canCraft = false
    local cmds = SP.Craft.collect(0)
    CraftMock.canCraft = nil
    CraftMock.restore(); RecipeDB.restore(); SP.Craft._recipes = nil
    local saw
    for _, c in ipairs(cmds) do if c.label == "Saw Log" then saw = c end end
    if not Assert.notNil(saw, "holding the Log surfaces 'Saw Log' even without the saw") then return false end
    if not Assert.equal(saw.runnable, false, "shown blocked (almost-possible, not runnable)") then return false end
    return Assert.notNil(saw.blockReason, "and says what you still need")
end

tests["no_near_miss_for_a_subject_you_dont_hold"] = function()
    -- Empty bag -> no near-misses (the flood guard: only recipes whose subject you carry)
    SP.Craft._recipes = nil
    RecipeDB.install()
    CraftMock.install({}); CraftMock.canCraft = false
    local cmds = SP.Craft.collect(0)
    CraftMock.canCraft = nil
    CraftMock.restore(); RecipeDB.restore(); SP.Craft._recipes = nil
    return Assert.equal(#cmds, 0, "nothing held -> no craft rows at all (no flood)")
end

return tests
