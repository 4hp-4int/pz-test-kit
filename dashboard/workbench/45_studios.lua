--[[
    Workbench studios: authoring tools for TEXT GENERATORS.

    The addon surfaces in 40_addons.lua are about ITEMS (panels on an item,
    actions on an item, board actions over slotted items). A studio is about a
    GENERATOR: something that composes text from seeded draws -- a story
    composer, a weapon-name composer, a tape script. It lives on the same
    addon declaration, and the browser (/studio, studio.html) builds every
    view from it, so a mod adds one by writing Lua, never HTML:

        WB.addon {
            id = "composers", name = "...",
            studios = {
                { id = "signal", label = "The frequency", doc = "...",
                  params = { { name = "seed", type = "number", default = 7 }, ... },

                  -- LISTEN (required): what the generator said, in order.
                  --   rows[i] = { at = "day 12", day = 12, text = "...",
                  --               trace = { era=, shape=, slots = { {slot=, frag=, family=, turn=, weight=, total=, of=}, ... } },
                  --               q = { fidelity = 40, ... } }       -- any numbers worth charting
                  listen = function(p, ctx) return { rows = rows, meta = {} } end,

                  -- CURVES (optional): how the generator moves over time.
                  --   { xLabel = "day", x = {1,2,...}, series = { { name =, values = {...}, group = }, ... } }
                  curves = function(p, ctx) return {...} end,

                  -- A/B (optional): apply temporary overrides, return an undo.
                  --   overrides = { { kind = "text", id = "frag_id", value = "new text" },
                  --                 { kind = "weight", id = "frag_id", value = 3 }, ... }
                  apply = function(overrides) return function() restore() end end,

                  -- FRAGMENTS (optional): the editable units, for the A/B picker.
                  --   { { id =, text =, group =, tags = {...} }, ... }
                  fragments = function(p) return {...} end,
                },
            },
        }

    Generators are expected to be PURE and SEEDED: the A/B view runs listen
    twice with the same params and diffs row by row, which only means
    anything if the same params give the same rows. A generator that reads
    the clock or ZombRand will show diffs nobody made.

    Wear (airings per fragment, first repeat, back-to-back same-family turns)
    is computed in the browser from listen's traces, so any studio that
    traces gets it for free.

    Tools: studios{}  studioRun{addon, studio, view = "listen"|"curves"|"fragments"|"ab", params, overrides}
]]

local function studioDef(addonId, studioId)
    local a = WB.addons[addonId]
    if not a then error("no addon " .. tostring(addonId)) end
    if a.disabled then error(a.name .. " is disabled: " .. a.disabled) end
    for _, s in ipairs(a.studios or {}) do if s.id == studioId then return a, s end end
    error(a.name .. " has no studio " .. tostring(studioId))
end

-- Same coercion rules as addon action params (40_addons.lua normParams).
local function normParams(def, given)
    local p = {}
    for k, v in pairs(given or {}) do p[k] = v end
    for _, spec in ipairs(def.params or {}) do
        local v = p[spec.name]
        if v == nil or v == "" then v = spec.default end
        if spec.type == "number" and v ~= nil then v = tonumber(v) end
        if spec.type == "bool" then v = v == true or v == "true" end
        p[spec.name] = v
    end
    return p
end

local function ctxFor()
    local log = {}
    return { log = function(m) log[#log + 1] = tostring(m) end }, log
end

local function describeParams(params)
    local out = {}
    for _, sp in ipairs(params or {}) do
        out[#out + 1] = { name = sp.name, label = sp.label or sp.name, type = sp.type or "string",
                          default = sp.default, options = sp.options, doc = sp.doc }
    end
    return out
end

WB.register("studios", function()
    local list = {}
    for _, id in ipairs(WB.addonOrder) do
        local a = WB.addons[id]
        for _, s in ipairs(a.studios or {}) do
            list[#list + 1] = {
                addon = a.id, addonName = a.name, id = s.id, label = s.label or s.id, doc = s.doc,
                disabled = a.disabled, params = describeParams(s.params),
                has = { listen = type(s.listen) == "function", curves = type(s.curves) == "function",
                        ab = type(s.apply) == "function", fragments = type(s.fragments) == "function" },
            }
        end
    end
    return { studios = list, loadErrors = WB.addonLoadErrors }
end)

-- Run fn(p, ctx), always restoring an applied override set even on error.
local function withOverrides(s, overrides, fn)
    local undo
    if overrides and #overrides > 0 then
        if type(s.apply) ~= "function" then error("studio " .. s.id .. " has no apply(): A/B unavailable") end
        undo = s.apply(overrides)
    end
    local ok, res = pcall(fn)
    if type(undo) == "function" then undo() end
    if not ok then error(res, 0) end
    return res
end

WB.register("studioRun", function(a)
    local _, s = studioDef(a.addon, a.studio)
    local p = normParams(s, a.params)
    local view = a.view or "listen"
    local ctx, log = ctxFor()
    local t0 = _pz_now_ms and _pz_now_ms() or 0
    local result
    if view == "listen" then
        result = withOverrides(s, a.overrides, function() return s.listen(p, ctx) end)
    elseif view == "ab" then
        -- Same params twice; the second with the overrides applied. The
        -- generator is seeded, so every difference is the edit's.
        local base = s.listen(p, ctx)
        local alt = withOverrides(s, a.overrides, function() return s.listen(p, ctx) end)
        result = { base = base, alt = alt }
    elseif view == "curves" then
        if type(s.curves) ~= "function" then error("studio " .. s.id .. " has no curves()") end
        result = withOverrides(s, a.overrides, function() return s.curves(p, ctx) end)
    elseif view == "fragments" then
        if type(s.fragments) ~= "function" then error("studio " .. s.id .. " has no fragments()") end
        result = { fragments = s.fragments(p) }
    else
        error("unknown studio view " .. tostring(view))
    end
    result = result or {}
    result.log = log
    result.params = p
    if _pz_now_ms then result.ms = _pz_now_ms() - t0 end
    return result
end)
