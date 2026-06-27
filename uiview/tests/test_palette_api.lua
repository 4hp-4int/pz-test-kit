--[[ pal_api — the public addon API facade + lifecycle event bus.
     Locks the bus mechanics (subscribe/emit, pcall isolation, veto + transform
     return semantics, unknown-name safety) and the facade (VERSION, capabilities,
     delegation to internals). End-to-end: an onCommands hook filters the displayed
     list through the real setAllCommands chokepoint. ]]
local Assert = PZTestKit.Assert
require "palette/pal_api"
local SP  = _G.SaucePalette
local EV  = SP.Events
local API = SP.API

-- fresh subscriber table per test so cross-test handlers don't leak
local function reset() EV._subs = {} end

local tests = {}

-- ── bus mechanics ──────────────────────────────────────────────────────────
tests["subscribe_and_emit"] = function()
    reset()
    local seen = nil
    API.on("onAfterRun", function(c) seen = c end)
    EV.emit("onAfterRun", { label = "Eat Apple" })
    return Assert.equal(seen and seen.label, "Eat Apple", "subscriber receives the payload")
end

tests["unknown_event_and_nonfn_ignored"] = function()
    reset()
    if not Assert.isTrue(API.on("onNonsense", function() end) == false, "unknown event name rejected") then return false end
    if not Assert.isTrue(API.on("onOpen", "not a function") == false, "non-function rejected") then return false end
    return Assert.isTrue(API.on("onOpen", function() end) == true, "valid registration accepted")
end

tests["pcall_isolation"] = function()
    reset()
    local reached = false
    API.on("onClose", function() error("addon blew up") end)   -- must not propagate
    API.on("onClose", function() reached = true end)            -- still runs
    -- emit logs the caught addon error (correct mod behaviour); silence that one
    -- expected diagnostic so the test run stays clean.
    local realPrint = _G.print
    _G.print = function() end
    local ok = pcall(function() EV.emit("onClose") end)
    _G.print = realPrint
    if not Assert.isTrue(ok, "a throwing subscriber does not propagate out of emit") then return false end
    return Assert.isTrue(reached, "later subscribers still run after one throws")
end

tests["before_run_veto"] = function()
    reset()
    API.on("onBeforeRun", function() return true end)    -- a non-false return does NOT veto
    if not Assert.isTrue(EV.emit("onBeforeRun", {}) ~= false, "non-false return allows the run") then return false end
    API.on("onBeforeRun", function() return false end)   -- one false vetoes
    return Assert.isTrue(EV.emit("onBeforeRun", {}) == false, "a false return vetoes")
end

tests["commands_transform_inplace_and_replace"] = function()
    reset()
    -- in-place mutation is kept
    API.on("onCommands", function(list) table.remove(list, 1) end)
    local out = EV.emit("onCommands", { { label = "A" }, { label = "B" } })
    if not Assert.equal(#out, 1, "in-place removal is reflected") then return false end
    if not Assert.equal(out[1].label, "B", "the right element remains") then return false end
    -- a returned table replaces the working list
    reset()
    API.on("onCommands", function() return { { label = "Z" } } end)
    local rep = EV.emit("onCommands", { { label = "A" } })
    return Assert.equal(rep[1].label, "Z", "a returned table replaces the list")
end

-- ── the facade ─────────────────────────────────────────────────────────────
tests["facade_version_and_capabilities"] = function()
    if not Assert.isTrue(type(API.VERSION) == "number", "API.VERSION is a number") then return false end
    if not Assert.isTrue(API.capabilities.events == true, "events capability advertised") then return false end
    return Assert.isTrue(API.capabilities.sources == true and API.capabilities.actions == true,
        "core capabilities advertised")
end

tests["facade_register_source_delegates"] = function()
    SP.sources = SP.sources or {}
    local before = #SP.sources
    API.registerSource({ id = "test_addon_src", collect = function() return {} end })
    if not Assert.equal(#SP.sources, before + 1, "registerSource delegates to SP.sources") then return false end
    return Assert.equal(SP.sources[#SP.sources].id, "test_addon_src", "the source landed")
end

tests["facade_declare_delegates"] = function()
    require "palette/pal_action"
    local c = API.declare({ display = { name = "Do Thing" }, category = "use", run = function() end })
    if not Assert.equal(c.label, "Do Thing", "declare flattens display.name -> label") then return false end
    return Assert.equal(c.category, "use", "flat fields pass through")
end

tests["facade_optbool_default_safe"] = function()
    -- with no PZAPI option registered, optBool returns the supplied default
    return Assert.isTrue(API.optBool("definitely_unset_opt", true) == true, "optBool falls back to default")
end

-- ── M2: registerCategory ────────────────────────────────────────────────────
tests["register_category_wires_chip_rank_intent"] = function()
    require "palette/pal_filter"     -- SP.Filter.CAT_RANK
    require "palette/pal_synonyms"   -- intentFor / registerCategoryIntent
    local T = require "palette/pal_theme"
    local ok = API.registerCategory({
        id = "smith", label = "SMITH", color = { 0.8, 0.5, 0.3 }, rank = 7,
        intent = "forge anvil temper quench",
    })
    if not Assert.isTrue(ok == true, "registerCategory returns true") then return false end
    local chip = T.color.category.smith
    if not Assert.isTrue(chip ~= nil and chip[1] == "SMITH", "chip label set in pal_theme") then return false end
    if not Assert.isTrue(chip[2] == 0.8, "chip colour set") then return false end
    if not Assert.equal(SP.Filter.CAT_RANK.smith, 7, "rank set in CAT_RANK") then return false end
    return Assert.isTrue(SP.Synonyms.intentFor("smith"):find("anvil", 1, true) ~= nil,
        "intent vocabulary registered for the category")
end

tests["register_category_partial_label_only"] = function()
    local T = require "palette/pal_theme"
    API.registerCategory({ id = "ztest", label = "ZONE", color = { 0.1, 0.2, 0.3 } })
    API.registerCategory({ id = "ztest", label = "ZONE2" })   -- retint label only (no colour)
    if not Assert.equal(T.color.category.ztest[1], "ZONE2", "label-only retints existing chip") then return false end
    return Assert.equal(T.color.category.ztest[2], 0.1, "colour preserved on a label-only retint")
end

tests["register_category_rejects_bad_spec"] = function()
    if not Assert.isTrue(API.registerCategory(nil) == false, "nil spec rejected") then return false end
    return Assert.isTrue(API.registerCategory({ label = "x" }) == false, "spec without id rejected")
end

-- (source heavy/enabled flags + canPause live in test_palette_sources.lua: those
--  tests `require pal_main` — loading the whole mod — which would destabilize the
--  lightweight States.build harness the onCommands integration test below relies on.)

-- ── end-to-end: the transform hook fires through the real display chokepoint ──
tests["on_commands_fires_through_setAllCommands"] = function()
    local States = require "UIView/scenes/PaletteStates"
    reset()
    local fired, sawCount = false, 0
    API.on("onCommands", function(list, ctx)
        fired = true
        sawCount = #list
    end)
    States.build({})   -- a normal open routes its command list through setAllCommands
    if not Assert.isTrue(fired, "onCommands fired during a real palette build") then return false end
    return Assert.isTrue(sawCount > 0, "the hook received the populated command list")
end

return tests
