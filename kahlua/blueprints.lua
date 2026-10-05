--[[
    PZTestKit.Blueprints -- Engine Workbench blueprints as tests.

    A blueprint (<mod>/workbench/blueprints/*.json) is a board: item cards
    with prep steps, recipe and board-action cards wired between them, and
    expectations. This runs one the way the board does -- same tools, same
    order, same input pinning, same output mapping, same checks -- inside an
    ordinary engine-mode test run, so every template is a regression test:

        -- media/lua/client/<Mod>/Tests/EngineBlueprintTests.lua
        if not (PZEngine and PZEngine.available()) then return {} end
        return PZTestKit.Blueprints.tests()

    The workbench's own Lua tools (pz-test-kit/dashboard/workbench/*.lua) and
    the addons (kit, mod, dependencies) are loaded into the test VM first,
    through the runner's read-only _pz_read_file / _pz_list_dir.

    Port of dashboard/workbench.html: replay(), craft(), runAction(),
    slotsOf(), showExpect(). A change to how the board runs a blueprint
    belongs in both places.
]]

PZTestKit = PZTestKit or {}
local BP = {}
PZTestKit.Blueprints = BP

-- ── JSON (enough for blueprint files) ──────────────────────────────────────
local function decode(s)
    local i = 1
    local function ws() i = (s:find("[^ \t\r\n]", i)) or (#s + 1) end
    local value
    local function str()
        local out, j = {}, i + 1
        while true do
            local c = s:sub(j, j)
            if c == "" then error("blueprint JSON: unterminated string") end
            if c == '"' then i = j + 1; break end
            if c == "\\" then
                local e = s:sub(j + 1, j + 1)
                local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                if e == "u" then
                    local code = tonumber(s:sub(j + 2, j + 5), 16) or 63
                    out[#out + 1] = code < 128 and string.char(code) or "?"
                    j = j + 6
                else
                    out[#out + 1] = map[e] or e
                    j = j + 2
                end
            else
                out[#out + 1] = c
                j = j + 1
            end
        end
        return table.concat(out)
    end
    value = function()
        ws()
        local c = s:sub(i, i)
        if c == "{" then
            local t = {}
            i = i + 1; ws()
            if s:sub(i, i) == "}" then i = i + 1; return t end
            while true do
                ws(); local k = str(); ws()
                i = i + 1        -- ':'
                t[k] = value(); ws()
                local d = s:sub(i, i); i = i + 1
                if d == "}" then return t end
            end
        elseif c == "[" then
            local t = {}
            i = i + 1; ws()
            if s:sub(i, i) == "]" then i = i + 1; return t end
            while true do
                t[#t + 1] = value(); ws()
                local d = s:sub(i, i); i = i + 1
                if d == "]" then return t end
            end
        elseif c == '"' then return str()
        elseif s:sub(i, i + 3) == "true" then i = i + 4; return true
        elseif s:sub(i, i + 4) == "false" then i = i + 5; return false
        elseif s:sub(i, i + 3) == "null" then i = i + 4; return nil
        else
            local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
            if not num or num == "" then error("blueprint JSON: unexpected '" .. c .. "' at " .. i) end
            i = i + #num
            return tonumber(num)
        end
    end
    return value()
end
BP.decode = decode

local function read(path) return _pz_read_file and _pz_read_file(path) end
local function list(path) return _pz_list_dir and _pz_list_dir(path) end
local function luaFiles(dir)
    local out = {}
    for _, n in ipairs(list(dir) or {}) do if n:sub(-4) == ".lua" then out[#out + 1] = n end end
    table.sort(out)
    return out
end

local function depRoots()
    local out = {}
    local cfg = _pz_config
    for _, d in ipairs((type(cfg) == "table" and cfg.dependencies) or {}) do
        if type(d) == "string" then out[#out + 1] = _pz_mod_root .. "/" .. d end
    end
    return out
end

-- ── the workbench's tools + addons, in the bridge's order ──────────────────
local loaded = false
function BP.loadWorkbench()
    if loaded then return end
    if not (_pz_read_file and _pz_kit_dir) then error("this kit's runner has no file reader (_pz_read_file)") end
    local dir = _pz_kit_dir .. "/dashboard/workbench/"
    local files = luaFiles(dir)
    table.sort(files, function(a, b)
        if a == "00_prelude.lua" then return b ~= a end
        if b == "00_prelude.lua" then return false end
        return a < b
    end)
    for _, f in ipairs(files) do
        local chunk, err = _pz_compile(read(dir .. f), "workbench/" .. f)
        if not chunk then error("workbench/" .. f .. ": " .. tostring(err)) end
        chunk()
    end
    local dirs, seen = { dir .. "addons/", _pz_mod_root .. "/workbench/" }, {}
    for _, r in ipairs(depRoots()) do dirs[#dirs + 1] = r .. "/workbench/" end
    for _, d in ipairs(dirs) do
        local key = d:lower()
        if not seen[key] then
            seen[key] = true
            for _, f in ipairs(luaFiles(d)) do
                local label = d .. f
                WB.currentAddonFile = label
                local chunk, err = _pz_compile(read(label), label)
                local ok, e2 = false, err
                if chunk then ok, e2 = pcall(chunk) end
                if not ok then WB.addonLoadError(label, tostring(e2)) end
            end
        end
    end
    WB.currentAddonFile = nil
    WB.scriptOutputs = WB.scriptOutputs or {}
    loaded = true
end

-- ── workstations: recipe Tags vs a CraftBench's Recipes (the board's index) ─
local OPEN_TAGS = { inhandcraft = true, anysurfacecraft = true, cannotberesearched = true }
local benches
local function scanScripts(dir, out, depth)
    if depth > 6 then return end
    for _, n in ipairs(list(dir) or {}) do
        local p = dir .. "/" .. n
        if n:sub(-4) == ".txt" then
            local text = read(p)
            if text and text:find("CraftBench", 1, true) then out[#out + 1] = text end
        elseif not n:find("%.") then
            scanScripts(p, out, depth + 1)
        end
    end
end
local function benchIndex()
    if benches then return benches end
    benches = {}
    local texts = {}
    local pz = _pz_install_dir and (_pz_install_dir:gsub("\\", "/") .. "/media/scripts")
    if pz then scanScripts(pz .. "/entities", texts, 0); scanScripts(pz .. "/generated/entities", texts, 0) end
    scanScripts(_pz_mod_root .. "/media/scripts", texts, 0)
    for _, r in ipairs(depRoots()) do scanScripts(r .. "/media/scripts", texts, 0) end
    for _, text in ipairs(texts) do
        local pos = 1
        while true do
            local s0, e0, name = text:find("entity%s+([%w_]+)%s*{", pos)
            if not s0 then break end
            local depth, j = 0, e0
            for k = e0, #text do
                local ch = text:sub(k, k)
                if ch == "{" then depth = depth + 1 elseif ch == "}" then depth = depth - 1; if depth == 0 then j = k; break end end
            end
            local block = text:sub(e0, j)
            local cb = block:match("component%s+CraftBench%s*(%b{})")
            local tags = cb and cb:match("Recipes%s*=%s*([^,\n]+)")
            -- The first REAL tile of the first row: multi-square layouts pad
            -- the grid with `false` (Charcoal_Pit's top row is
            -- "false crafted_01_126"), and a bench built on "false" has no
            -- CraftBench, so the craft silently ran in hand.
            local sprite
            for row in block:gmatch("row%s*=%s*([^,\n]+)") do
                for tok in row:gmatch("[%w_]+") do
                    if tok ~= "false" then sprite = tok; break end
                end
                if sprite then break end
            end
            if tags and sprite then
                local set = {}
                for t in tags:gmatch("[^;]+") do set[t:gsub("^%s+", ""):gsub("%s+$", ""):lower()] = true end
                benches[#benches + 1] = { name = "Base." .. name, tags = set, sprite = sprite }
            end
            pos = j + 1
        end
    end
    return benches
end
function BP.benchFor(recipeName, preferred)
    local r = WB.findRecipe(recipeName)
    if not r then return nil end
    local need = {}
    for _, t in ipairs(WB.list(WB.try(function() return r:getTags() end))) do
        t = tostring(t):lower()
        if not OPEN_TAGS[t] then need[#need + 1] = t end
    end
    if #need == 0 then return nil end
    local first
    for _, b in ipairs(benchIndex()) do
        for _, t in ipairs(need) do
            if b.tags[t] then
                if preferred and b.name == preferred then return { name = b.name, sprite = b.sprite } end
                first = first or { name = b.name, sprite = b.sprite }
            end
        end
    end
    return first
end

-- ── replay (port of the board) ──────────────────────────────────────────────
local function T(name, args) return WB.tools[name](args or {}) end
local function copy(v)
    if type(v) ~= "table" then return v end
    local o = {}
    for k, x in pairs(v) do o[k] = copy(x) end
    return o
end
local function badgesOf(c)
    local parts = {}
    for _, b in ipairs((c and c.snap and c.snap.badges) or {}) do parts[#parts + 1] = tostring(b.text) end
    return table.concat(parts, " | ")
end

function BP.run(bp)
    BP.loadWorkbench()
    local cards, byId = {}, {}
    for _, t in ipairs(bp.cards or {}) do
        local c = copy(t)
        cards[#cards + 1] = c
        byId[c.id] = c
    end
    local function isProc(c) return c.kind == "recipe" or c.kind == "action" end
    local function isStock(c) return c.kind == "item" and (c.count or 1) > 1 end
    local function ready(c)
        if isStock(c) then return not c.consumed end
        return c.ref ~= nil and not c.consumed and not c.stale
    end
    local catalog = (T("boardActions") or {}).actions or {}
    for _, c in ipairs(cards) do
        if c.kind == "recipe" then
            c.inputs = c.inputs or {}; c.outputs = c.outputs or {}
        elseif c.kind == "action" then
            local def
            for _, d in ipairs(catalog) do if d.addon == c.addon and d.id == c.action then def = d end end
            c.slotDefs = def and def.slots or {}
            if not def then for k in pairs(c.slots or {}) do c.slotDefs[#c.slotDefs + 1] = { name = k, label = k } end end
            c.slots = c.slots or {}; c.outMap = c.outMap or {}
            c.inputs = {}
            for _, s in ipairs(c.slotDefs) do if c.slots[s.name] then c.inputs[#c.inputs + 1] = c.slots[s.name] end end
        end
    end
    local rng = bp.rng or { mode = "seeded", seed = 1 }
    T("setRandom", { mode = rng.mode == "midpoint" and "midpoint" or "seeded", seed = rng.seed or 1 })

    local function applySteps(c)
        for _, st in ipairs(c.steps or {}) do
            local r = T("addonRun", { ref = c.ref, addon = st.addon, action = st.action, params = st.params or {} })
            if not r.ok then c.err = st.addon .. "/" .. st.action .. ": " .. tostring(r.err); return end
            c.snap = r.item
        end
    end
    for _, c in ipairs(cards) do
        if c.kind == "item" and not c.origin and not isStock(c) then
            local snap = T("addonPanels", { type = c.type })
            c.ref, c.snap = snap.ref, snap
            applySteps(c)
        end
    end

    local rdefs = {}
    local function slotPins(r, ins)
        local d = rdefs[r.recipe]
        if d == nil then local ok, v = pcall(T, "recipe", { name = r.recipe }); d = ok and v or false; rdefs[r.recipe] = d end
        if not d then return {} end
        local rows = {}
        for _, inp in ipairs(d.inputs or {}) do
            rows[#rows + 1] = { inp = inp, role = inp.resource ~= "Item" and "other" or "item", have = 0,
                                need = math.max(1, inp.itemsNeeded or inp.intAmount or math.ceil(inp.amount or 1)) }
        end
        local pins, extra = {}, false
        for _, c in ipairs(ins) do
            local fits = {}
            for _, row in ipairs(rows) do
                if row.role ~= "other" then
                    local accepts = row.inp.anyItem
                    for _, t in ipairs(row.inp.items or {}) do if t == c.type then accepts = true end end
                    if accepts then fits[#fits + 1] = row end
                end
            end
            local row
            for _, x in ipairs(fits) do if x.have < x.need then row = x; break end end
            row = row or fits[1]
            if not row then extra = true else
                pins[c.id] = row.inp.index
                row.have = row.have + (isStock(c) and (c.count or 1) or 1)
            end
        end
        return extra and {} or pins
    end

    local function craft(r)
        local ins = {}
        for _, id in ipairs(r.inputs) do if byId[id] then ins[#ins + 1] = byId[id] end end
        local pins = slotPins(r, ins)
        local specs = {}
        for _, c in ipairs(ins) do
            local s = isStock(c) and { type = c.type, count = c.count, steps = c.steps } or { ref = c.ref, type = c.type }
            s.input = pins[c.id]
            specs[#specs + 1] = s
        end
        local bench
        if r.bench ~= false then bench = BP.benchFor(r.recipe, r.bench) end
        local ok, res = pcall(T, "craft", { recipe = r.recipe, items = specs, qualify = true, mode = "action", enforce = true, bench = bench })
        if not ok then r.result = { ok = false, err = tostring(res) }; return end
        local consumed, kept = {}, {}
        for _, x in ipairs(res.consumed or {}) do consumed[x.ref] = x end
        for _, x in ipairs(res.kept or {}) do kept[x.ref] = x end
        for _, c in ipairs(ins) do
            if isStock(c) then if res.ok then c.consumed = true end
            else
                if consumed[c.ref] then c.consumed = true end
                if kept[c.ref] then for k, v in pairs(kept[c.ref]) do c.snap = c.snap or {}; c.snap[k] = v end end
            end
        end
        local old, used = {}, {}
        for _, id in ipairs(r.outputs) do if byId[id] then old[#old + 1] = byId[id] end end
        r.outputs = {}
        for i, o in ipairs(res.outputs or {}) do
            local c
            for _, x in ipairs(old) do if not used[x.id] and x.type == o.fullType then c = x; break end end
            if not c then for _, x in ipairs(old) do if not used[x.id] and not x.type then c = x; break end end end
            if not c then c = { id = r.id .. ":out" .. i, kind = "item", steps = {}, origin = r.id }; cards[#cards + 1] = c; byId[c.id] = c end
            used[c.id] = true
            c.type, c.ref, c.snap, c.consumed, c.stale, c.err = o.fullType, o.ref, o, false, false, nil
            r.outputs[#r.outputs + 1] = c.id
        end
        for _, c in ipairs(old) do if not used[c.id] then c.ref, c.snap, c.stale = nil, nil, true; r.outputs[#r.outputs + 1] = c.id end end
        for _, id in ipairs(r.outputs) do local c = byId[id]; if c.ref and c.steps and #c.steps > 0 then applySteps(c) end end
        r.result = res
    end

    local function runAction(a)
        local slots = {}
        for k, v in pairs(a.slots) do if byId[v] then slots[k] = byId[v].ref end end
        local ok, res = pcall(T, "boardActionRun", { addon = a.addon, action = a.action, slots = slots, params = a.params or {}, mode = a.mode or "sp" })
        if not ok then a.result = { ok = false, err = tostring(res) }; return end
        local placed = {}
        local function place(key, info)
            local c = a.outMap[key] and byId[a.outMap[key]]
            if not c then c = { id = a.id .. ":" .. key, kind = "item", steps = {}, origin = a.id }; cards[#cards + 1] = c; byId[c.id] = c; a.outMap[key] = c.id end
            c.type, c.ref, c.snap, c.stale, c.consumed = info.fullType, info.ref, info, false, info.gone and true or false
            placed[c.id] = true
        end
        for _, s in ipairs(a.slotDefs) do
            local info = res.slots and res.slots[s.name]
            local inCard = byId[a.slots[s.name]]
            if info and inCard then inCard.consumed = true; place("slot:" .. s.name, info) end
        end
        for k, info in ipairs(res.created or {}) do place("new:" .. (k - 1), info) end
        for _, id in pairs(a.outMap) do if not placed[id] and byId[id] then byId[id].stale = true; byId[id].ref = nil end end
        a.result = { ok = res.ok, err = res.err, commands = res.commands, log = res.log, mode = res.mode }
    end

    local todo = {}
    for _, c in ipairs(cards) do if isProc(c) then todo[#todo + 1] = c end end
    local progressed = true
    while #todo > 0 and progressed do
        progressed = false
        local i = 1
        while i <= #todo do
            local r = todo[i]
            local ins, allReady = {}, true
            for _, id in ipairs(r.inputs) do if byId[id] then ins[#ins + 1] = byId[id] end end
            for _, c in ipairs(ins) do if not ready(c) then allReady = false end end
            if #ins > 0 and allReady then
                table.remove(todo, i)
                if r.kind == "action" then runAction(r) else craft(r) end
                progressed = true
            else
                i = i + 1
            end
        end
    end

    -- expectations (port of showExpect)
    local results = {}
    for _, e in ipairs(bp.expect or {}) do
        local ok, what = false, ""
        if e.card then
            local c = byId[e.card]
            local t, n = badgesOf(c), (c and c.snap and c.snap.name) or (c and c.type) or "?"
            if e.badge then ok = t:find(e.badge, 1, true) ~= nil; what = n .. ' has "' .. e.badge .. '"' end
            if e.noBadge then ok = t:find(e.noBadge, 1, true) == nil; what = n .. ' has no "' .. e.noBadge .. '"' end
            if e.uses ~= nil then local u = c and c.snap and c.snap.uses; ok = u == e.uses; what = n .. " has " .. e.uses .. " uses (got " .. tostring(u) .. ")" end
            if e.condition ~= nil then local u = c and c.snap and c.snap.condition; ok = u == e.condition; what = n .. " has condition " .. e.condition .. " (got " .. tostring(u) .. ")" end
        end
        if e.outputsOf then
            local r, count = byId[e.outputsOf], 0
            for _, id in ipairs((r and r.outputs) or {}) do if badgesOf(byId[id]):find(e.badge, 1, true) then count = count + 1 end end
            ok = count == e.count
            what = e.count .. " output(s) of " .. tostring(r and (r.label or r.recipe)) .. ' with "' .. e.badge .. '" (got ' .. count .. ")"
        end
        if e.recipe and e.command then
            local r = byId[e.recipe]
            for _, x in ipairs((r and r.result and r.result.commands) or {}) do if x.command == e.command then ok = true end end
            what = tostring(r and (r.label or r.recipe or r.action)) .. " sends " .. e.command
        elseif e.recipe and e.crafted ~= nil then
            local r = byId[e.recipe]
            local got = (r and r.result and r.result.ok) and true or false
            ok = got == e.crafted
            what = tostring(r and (r.label or r.recipe)) .. (e.crafted and " crafts" or " is refused") .. (r and r.result and (got and " (crafted)" or " (refused)") or " (not run)")
        end
        results[#results + 1] = { ok = ok, what = what, card = e.card or e.outputsOf or e.recipe }
    end
    local stuck = #todo
    return { results = results, stuck = stuck, cards = cards }
end

-- Listeners registered while a board runs, carried into later boards.
-- The executor scopes Events per test (snapshot before, restore after), but
-- what registers here is mostly MODULE LOADS -- the workbench, addons, a
-- mod's adapter required lazily by the first board that needs it -- and
-- those load once and stay cached. Scoped away, every board after the
-- first ran without them: the story adapter's LoadGridsquare (queued
-- placements, the heirloom coming home) and RadioHost's OnLoadRadioScripts
-- (the walkie) both vanished, and those boards only ever passed when
-- alphabetical order made them first. In game these register once per
-- session; carried here, a board sees the session the boards before it
-- built. The executor still restores every TEST to its own snapshot.
local carried = {}
local function listenersOf(evName)
    local e = type(Events) == "table" and rawget(Events, evName)
    return type(e) == "table" and type(e._listeners) == "table" and e._listeners or nil
end
local function restoreCarried()
    for evName, fns in pairs(carried) do
        local e = type(Events) == "table" and Events[evName]
        if type(e) == "table" then
            e._listeners = e._listeners or {}
            local have = {}
            for _, fn in ipairs(e._listeners) do have[fn] = true end
            for _, fn in ipairs(fns) do
                if not have[fn] then e._listeners[#e._listeners + 1] = fn; have[fn] = true end
            end
        end
    end
end
local function snapshotListeners()
    local snap = {}
    if type(Events) ~= "table" then return snap end
    for evName in pairs(Events) do
        local l = listenersOf(evName)
        if l then
            local set = {}
            for _, fn in ipairs(l) do set[fn] = true end
            snap[evName] = set
        end
    end
    return snap
end
local function carryNew(before)
    if type(Events) ~= "table" then return end
    for evName in pairs(Events) do
        local l = listenersOf(evName)
        if l then
            local was = before[evName] or {}
            for _, fn in ipairs(l) do
                if not was[fn] then
                    carried[evName] = carried[evName] or {}
                    local dup = false
                    for _, x in ipairs(carried[evName]) do if x == fn then dup = true end end
                    if not dup then carried[evName][#carried[evName] + 1] = fn end
                end
            end
        end
    end
end

-- Every <mod>/workbench/blueprints/*.json as a test case.
function BP.tests(dir)
    local Assert = PZTestKit.Assert
    dir = dir or (_pz_mod_root .. "/workbench/blueprints")
    local tests = {}
    for _, n in ipairs(list(dir) or {}) do
        if n:sub(-5) == ".json" then
            tests["blueprint: " .. n:gsub("%.json$", "")] = function()
                local bp = decode(read(dir .. "/" .. n))
                restoreCarried()
                local before = snapshotListeners()
                local okRun, r = pcall(BP.run, bp)
                carryNew(before)
                if not okRun then error(r, 0) end
                local all = true
                if r.stuck > 0 then
                    Assert.isTrue(false, r.stuck .. " step(s) could not run (inputs missing or used twice)")
                    all = false
                end
                local byId = {}
                for _, c in ipairs(r.cards) do byId[c.id] = c end
                for _, x in ipairs(r.results) do
                    if not Assert.isTrue(x.ok, x.what) then
                        all = false
                        -- What the step that made this card did, for the log.
                        local c = byId[x.card]
                        local step = c and (c.result and c or byId[c.origin or ""])
                        local res = step and step.result
                        if res then
                            local cmds = {}
                            for _, cm in ipairs(res.commands or {}) do cmds[#cmds + 1] = tostring(cm.module) .. "/" .. tostring(cm.command) end
                            print("    step " .. tostring(step.id) .. ": ok=" .. tostring(res.ok) .. (res.err and (" err=" .. tostring(res.err)) or "")
                                .. " commands=[" .. table.concat(cmds, ", ") .. "]")
                            for _, l in ipairs(res.log or {}) do print("      log: " .. tostring(l)) end
                        end
                    end
                end
                if #r.results == 0 then Assert.isTrue(true, "ran (no expectations)") end
                return all
            end
        end
    end
    return tests
end
