--[[ pal_synonyms — the search-alias framework. Locks the index/expand mechanics
     and the open registration API, plus an end-to-end match (typing a synonym
     finds the row whose label/source contains an equivalent term). ]]
local Assert  = PZTestKit.Assert
local States  = require "UIView/scenes/PaletteStates"
require "palette/pal_synonyms"
local SP = _G.SaucePalette
local S  = SP.Synonyms

local function frameHasText(root, sub)
    local W, H = 1280, 800
    local Render = require "UIView/Render"
    local f = Render.capture(root, W, H)
    for _, op in ipairs(f.ops) do
        if op.op == "text" and op.str and op.str:find(sub, 1, true) then return true end
    end
    return false
end

local tests = {}

tests["builtin_defaults_loaded"] = function()
    -- the EN default set is loaded at require (harness has no Translate JSON, so
    -- it falls back to the built-in string).
    return Assert.isTrue(S.expand("oven"):find("stove", 1, true) ~= nil,
        "oven expands to include stove from the built-in default")
end

tests["expand_is_bidirectional"] = function()
    if not Assert.isTrue(S.expand("Turn On Chrome Oven"):find("stove", 1, true) ~= nil,
        "oven -> stove") then return false end
    return Assert.isTrue(S.expand("light a candle"):find("lamp", 1, true) ~= nil, "light -> lamp")
end

tests["expand_unrelated_is_empty"] = function()
    return Assert.equal(S.expand("frobnicate the wuzzle"), "", "no aliases for unknown words")
end

tests["register_group_table"] = function()
    local before = S.version
    SP.registerSynonyms({ "kerblammo", "boomstick", "zap" })
    if not Assert.isTrue(S.version > before, "registering bumps the version") then return false end
    if not Assert.isTrue(S.expand("kerblammo"):find("boomstick", 1, true) ~= nil, "new alias resolves") then return false end
    return Assert.isTrue(S.expand("zap"):find("kerblammo", 1, true) ~= nil, "bidirectional for the new group")
end

tests["register_list_and_string_forms"] = function()
    SP.registerSynonyms({ { "wibble", "wobble" }, { "fizz", "buzz" } })  -- list of groups
    SP.registerSynonyms("plover,xyzzy")                                  -- string form
    if not Assert.isTrue(S.expand("wibble"):find("wobble", 1, true) ~= nil, "list-of-groups form") then return false end
    return Assert.isTrue(S.expand("plover"):find("xyzzy", 1, true) ~= nil, "string form")
end

tests["synonym_query_finds_row"] = function()
    -- "genny" finds the generator row; "nap" finds Sleep — purely via synonyms
    -- (neither word is in the respective label/source).
    local g = States.build({ query = "genny" })
    if not Assert.isTrue(frameHasText(g, "Generator"), "'genny' surfaces the Generator row via synonym") then return false end
    local n = States.build({ query = "nap" })
    return Assert.isTrue(frameHasText(n, "Sleep"), "'nap' surfaces the Sleep row via synonym")
end

-- ── category intent ───────────────────────────────────────────────────────
tests["category_intent_builtin_loaded"] = function()
    -- the EN default category map is loaded at require; a tight category resolves
    -- to its concept vocabulary, broad/meta categories are intentionally absent.
    if not Assert.isTrue(S.intentFor("farm"):find("grow", 1, true) ~= nil,
        "farm intent includes 'grow'") then return false end
    if not Assert.isTrue(S.intentFor("med"):find("heal", 1, true) ~= nil,
        "med intent includes 'heal'") then return false end
    return Assert.equal(S.intentFor("world"), "", "broad 'world' category has no intent (would flood)")
end

tests["category_intent_register_and_dedup"] = function()
    local before = S.version
    SP.registerCategoryIntent({ frobcat = "wibble wobble wibble" })  -- map form, dup word
    if not Assert.isTrue(S.version > before, "registering bumps the version") then return false end
    if not Assert.isTrue(S.intentFor("frobcat"):find("wobble", 1, true) ~= nil, "new category intent resolves") then return false end
    SP.registerCategoryIntent("frobcat=zonk")                        -- string form, additive
    local _, n = S.intentFor("frobcat"):gsub("wibble", "")
    if not Assert.equal(n, 1, "duplicate word folded once") then return false end
    return Assert.isTrue(S.intentFor("frobcat"):find("zonk", 1, true) ~= nil, "string form adds to the same category")
end

tests["intent_for_unknown_is_empty"] = function()
    if not Assert.equal(S.intentFor("nope_not_a_category"), "", "unknown category -> no intent") then return false end
    return Assert.equal(S.intentFor(nil), "", "nil category is safe")
end

tests["directional_query_lights_up_category"] = function()
    -- a command whose LABEL contains no farming word still surfaces under a
    -- directional query, purely because it's in the farm category. Drive the real
    -- Filter with a synthetic farm row and a typed intent word.
    require "palette/pal_filter"
    local self = {
        playerNum = 0,
        allCommands = {
            { label = "Pluck Mulberries", source = "Bush", category = "farm", runnable = true },
            { label = "Open Window",      source = "Window", category = "world", runnable = true },
        },
    }
    SP.Filter.run(self, "grow")
    local hasFarm, hasWorld = false, false
    for _, c in ipairs(self.filtered) do
        if c.label == "Pluck Mulberries" then hasFarm = true end
        if c.label == "Open Window" then hasWorld = true end
    end
    if not Assert.isTrue(hasFarm, "'grow' surfaces the farm row though its label has no farming word") then return false end
    return Assert.isTrue(not hasWorld, "the unrelated world row is NOT pulled in by the directional query")
end

return tests
