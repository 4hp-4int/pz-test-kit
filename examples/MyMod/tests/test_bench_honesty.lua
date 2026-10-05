--[[
    Workbench bench honesty (2026-10-05): a craft at a workstation happens AT
    that workstation or fails. Each case below once passed while testing
    something else -- the Charcoal_Pit's `false`-padded first sprite row built
    no bench and the craft quietly ran in hand; a board naming a bench that
    did not serve its recipe was handed another one. Vanilla recipes only, so
    this guards the kit itself, for every mod.
]]

if not (PZEngine and PZEngine.available()) then return {} end
local Assert = PZTestKit.Assert
local BP = PZTestKit.Blueprints

local function board(recipe, bench)
    local r = BP.run({ cards = {
        { id = "logs", kind = "item", type = "Base.Log", count = 2 },
        { id = "r", kind = "recipe", recipe = recipe, bench = bench, inputs = { "logs" }, outputs = {} },
    }, expect = {} })
    for _, c in ipairs(r.cards) do if c.id == "r" then return c.result or {} end end
    return {}
end

local tests = {}

tests["a_bench_that_cannot_be_built_crafts_nothing"] = function()
    BP.loadWorkbench()
    local r = WB.tools.craft({ recipe = "Base.MakeWoodCharcoal", enforce = true,
        items = { { type = "Base.Log", count = 2 } }, bench = { name = "Base.Charcoal_Pit", sprite = "false" } })
    if not Assert.isFalse(r.ok, "not ok") then return false end
    if not Assert.isFalse(r.ran, "not run") then return false end
    return Assert.equal(#(r.consumed or {}), 0, "nothing consumed")
end

tests["the_charcoal_pit_resolves_to_its_real_tile"] = function()
    BP.loadWorkbench()
    local b = BP.benchFor("Base.MakeWoodCharcoal", "Base.Charcoal_Pit")
    if not Assert.equal(b and b.sprite, "crafted_01_126", "past the `false` padding") then return false end
    return Assert.isTrue(board("Base.MakeWoodCharcoal", "Base.Charcoal_Pit").ok == true, "and charcoal crafts there")
end

tests["a_named_bench_is_used_or_the_card_fails"] = function()
    BP.loadWorkbench()
    local wrong = board("Base.MakeWoodCharcoal", "Base.Kiln_Small")
    if not Assert.isFalse(wrong.ok == true, "a kiln is not a charcoal bench") then return false end
    if not Assert.isTrue(tostring(wrong.err):find("does not serve", 1, true) ~= nil, "and the card says why") then return false end
    return Assert.isFalse(board("Base.MakeWoodCharcoal", "Base.NoSuchBench").ok == true, "an unknown bench fails too")
end

tests["vanilla_benches_resolve_in_a_test_env"] = function()
    -- _pz_install_dir in every env: without it no vanilla bench resolved.
    BP.loadWorkbench()
    if not Assert.notNil(_pz_install_dir, "the install is visible") then return false end
    return Assert.notNil(BP.benchFor("Base.FireBrick"), "a kiln recipe finds a kiln")
end

return tests
