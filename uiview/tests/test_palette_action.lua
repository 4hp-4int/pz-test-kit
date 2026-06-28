--[[
    UIView — SaucePalette Action contract (Phase 5)
    ===============================================
    Exercises pal_action.lua: normalize (the ingestion guarantee), validate (the
    contract check), and declare (the provider authoring surface). These lock the
    contract so a future provider migration can't silently drift the shape the
    four engines read.
]]

local Assert = PZTestKit.Assert
local SP = require "palette/pal_action"
local A = SP.Action

local tests = {}

-- ── normalize ───────────────────────────────────────────────────────────────
tests["normalize_fills_defaults"] = function()
    local c = A.normalize({ label = "X", run = function() end })
    if not Assert.equal(c.kind, "action", "kind defaults to action") then return false end
    if not Assert.equal(c.category, "action", "category defaults to action") then return false end
    return Assert.isTrue(c.runnable == true, "runnable defaults to true")
end

tests["normalize_preserves_explicit_values"] = function()
    local c = A.normalize({ label = "X", kind = "place", category = "build",
                            runnable = false, run = function() end })
    if not Assert.equal(c.kind, "place", "explicit kind kept") then return false end
    if not Assert.equal(c.category, "build", "explicit category kept") then return false end
    return Assert.isTrue(c.runnable == false, "explicit runnable=false NOT clobbered to true")
end

tests["normalize_is_idempotent"] = function()
    local c = A.normalize({ label = "X", run = function() end })
    local k, cat, r = c.kind, c.category, c.runnable
    A.normalize(c)
    return Assert.isTrue(c.kind == k and c.category == cat and c.runnable == r,
        "second normalize is a no-op")
end

-- ── validate ──────────────────────────────────────────────────────────────
tests["validate_passes_well_formed"] = function()
    local c = A.normalize({ label = "Open Box", category = "craft",
                            run = function() end })
    return Assert.equal(#A.validate(c), 0, "a normalized command has no violations")
end

tests["validate_flags_missing_label"] = function()
    local c = A.normalize({ run = function() end })   -- no label
    return Assert.greater(#A.validate(c), 0, "missing label is a violation")
end

tests["validate_flags_no_executor"] = function()
    local c = A.normalize({ label = "X" })   -- no run / runN
    return Assert.greater(#A.validate(c), 0, "no run/runN is a violation")
end

tests["validate_flags_stringified_subject"] = function()
    -- the get(0) anti-pattern: a provider pre-stringifies the subject ref.
    local c = A.normalize({ label = "X", run = function() end, item = "Base.Hammer" })
    return Assert.greater(#A.validate(c), 0, "a string `item` (not a live ref) is a violation")
end

-- ── declare ───────────────────────────────────────────────────────────────
tests["declare_flattens_grouped_spec"] = function()
    local tex = {}   -- stand-in texture ref
    local c = A.declare({
        display  = { name = "Place: Generator", icon = tex, detail = function() end },
        category = "place", kind = "place",
        subject  = { item = { live = true }, square = { x = 1, y = 2, z = 3 } },
        input    = { name = "Box of Nails", type = "Base.NailsBox", icon = tex },
        why      = { block = "needs a Forge" },
        run      = function() end,
    })
    if not Assert.equal(c.label, "Place: Generator", "display.name -> label") then return false end
    if not Assert.isTrue(c.icon == tex, "display.icon -> icon") then return false end
    if not Assert.isTrue(type(c.buildDetail) == "function", "display.detail -> buildDetail") then return false end
    if not Assert.isTrue(c.item ~= nil and type(c.item) == "table", "subject.item -> item (live ref)") then return false end
    if not Assert.isTrue(c.sx == 1 and c.sy == 2 and c.sz == 3, "subject.square -> sx/sy/sz") then return false end
    if not Assert.equal(c.inputName, "Box of Nails", "input.name -> inputName") then return false end
    if not Assert.equal(c.inputType, "Base.NailsBox", "input.type -> inputType") then return false end
    if not Assert.equal(c.blockReason, "needs a Forge", "why.block -> blockReason") then return false end
    return Assert.equal(#A.validate(c), 0, "declared command is contract-valid")
end

tests["declare_flat_field_wins_over_alias"] = function()
    local c = A.declare({ label = "Explicit", display = { name = "Grouped" },
                          run = function() end })
    return Assert.equal(c.label, "Explicit", "explicit flat label beats display.name")
end

tests["declare_defaults_runnable_true"] = function()
    local c = A.declare({ display = { name = "X" }, run = function() end })
    return Assert.isTrue(c.runnable == true, "declare normalizes (runnable defaults true)")
end

return tests
