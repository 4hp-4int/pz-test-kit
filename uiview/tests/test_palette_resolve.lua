--[[ SP.Resolve.recipeOutput — the output-item verdict, with the OUTPUT MAPPER fix.
     An output mapper picks its result from the ACTUAL consumed input (dismantling a
     Fire Axe yields a Fire Axe Head). The script's `default = ...` is a fallback the
     mapper hands back when it can't see the input, so getItem(nil) on a mapper output
     returns that DEFAULT — the wrong item for everything but the default's own input.
     These lock: with live recipe data we get the real mapped item; without it we NEVER
     show the mapper default — a multi-result mapper is honest "various", a single one
     is concrete, and a plain fixed output still resolves. ]]
local Assert = PZTestKit.Assert
require "palette/pal_resolve"
local R = _G.SaucePalette.Resolve

local function fakeItem(name)
    return { getDisplayName = function() return name end, getNormalTexture = function() return nil end }
end

local function jlist(t)
    return { size = function() return #t end, get = function(_, i) return t[i + 1] end }
end

-- A fake OutputScript. opts:
--   fixed       = name returned by getItem(nil) when there's NO mapper (a fixed output)
--   mapper      = true to expose an OutputMapper
--   default     = name getItem(nil) returns for a MAPPER output (the wrong default)
--   mappedFor   = name getItem(recipeData) returns when recipe data is supplied
--   results     = { name, ... } the mapper's possible result items
local function fakeOutput(opts)
    return {
        getItem = function(_, rd)
            if opts.mapper then
                if rd ~= nil and opts.mappedFor then return fakeItem(opts.mappedFor) end
                return opts.default and fakeItem(opts.default) or nil   -- mapper default for getItem(nil)
            end
            return opts.fixed and fakeItem(opts.fixed) or nil
        end,
        getOutputMapper = function()
            if not opts.mapper then return nil end
            local items = {}
            for _, n in ipairs(opts.results or {}) do items[#items + 1] = fakeItem(n) end
            return {
                isEmpty = function() return #items == 0 end,
                getResultItems = function() return jlist(items) end,
            }
        end,
    }
end

local tests = {}

tests["mapper_with_recipedata_resolves_real_output"] = function()
    -- Dismantle Fire Axe: many possible heads, default HuntingKnifeBlade, but the
    -- live recipe data maps Base.Axe -> Fire Axe Head. We must show the mapped item.
    local o = fakeOutput{ mapper = true, default = "Hunting Knife Blade",
                          mappedFor = "Fire Axe Head", results = { "a", "b", "c" } }
    local v = R.recipeOutput(o, {})   -- non-nil recipe data
    if not Assert.equal(v.kind, "concrete", "concrete from live recipe data") then return false end
    return Assert.equal(v.name, "Fire Axe Head", "the input's actual mapped head, not the default")
end

tests["mapper_no_recipedata_multi_is_various_not_default"] = function()
    -- No recipe data + many possible results -> honest "various", NEVER the default.
    local o = fakeOutput{ mapper = true, default = "Hunting Knife Blade", results = { "a", "b", "c" } }
    local v = R.recipeOutput(o, nil)
    if not Assert.equal(v.kind, "various", "various when the input is unknown") then return false end
    return Assert.equal(v.name ~= "Hunting Knife Blade", true, "does NOT leak the mapper default")
end

tests["mapper_single_result_is_concrete"] = function()
    -- A mapper with exactly one possible result is unambiguous even with no data.
    local o = fakeOutput{ mapper = true, default = "X", results = { "Only Output" } }
    local v = R.recipeOutput(o, nil)
    if not Assert.equal(v.kind, "concrete", "single-result mapper is concrete") then return false end
    return Assert.equal(v.name, "Only Output", "names the lone result")
end

tests["input_names_the_resolved_item_not_various"] = function()
    -- A multi-item input ([NailsBox;ScrewsBox;CapGunCapBox]) is honestly "various"
    -- on its own, but when recipe data resolved it to the held Box of Nails we name
    -- that item — the detail input row reads "Box of Nails", not "various items".
    local inp = {
        getItemTags = function() return { isEmpty = function() return true end } end,
        getPossibleInputItems = function() return jlist({ fakeItem("a"), fakeItem("b"), fakeItem("c") }) end,
    }
    local resolvedItem = { getName = function() return "Box of Nails" end,
                           getTexture = function() return nil end, getFullType = function() return "Base.NailsBox" end }
    local v = R.recipeInput(inp, resolvedItem)
    if not Assert.equal(v.kind, "concrete", "concrete when an item was resolved") then return false end
    if not Assert.equal(v.name, "Box of Nails", "names the resolved box") then return false end
    -- and without a resolved item it stays honest "various" for a 3-item input
    local v2 = R.recipeInput(inp, nil)
    return Assert.equal(v2.kind, "various", "various with no resolved item")
end

tests["fixed_output_resolves_without_data"] = function()
    -- No mapper: a plain fixed output still resolves via getItem(nil).
    local o = fakeOutput{ fixed = "Wooden Plank" }
    local v = R.recipeOutput(o, nil)
    if not Assert.equal(v.kind, "concrete", "fixed output concrete") then return false end
    return Assert.equal(v.name, "Wooden Plank", "names the fixed item")
end

tests["humanizeTag_drops_prefix_and_prettifies"] = function()
    if not Assert.equal(R.humanizeTag("base:scissors"), "Scissors", "drops module prefix, Title-cases") then return false end
    if not Assert.equal(R.humanizeTag("base:fiberglasstape"), "Fiberglass Tape", "known lowercase compound") then return false end
    if not Assert.equal(R.humanizeTag("DigGrave"), "Dig Grave", "camelCase split") then return false end
    return Assert.equal(R.humanizeTag("base:epoxy"), "Epoxy", "plain word Title-cased")
end

return tests
