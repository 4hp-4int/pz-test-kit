--[[
    Recipe builder: draft a craftRecipe, write it into the mod, reload, craft.

    Tools:  recipeDraft{draft}     -> { text, path, full, exists, warnings }
            recipeParse{text}      -> draft (a craftRecipe block, e.g. the
                                      `recipe` tool's source text: fork it)

    draft = { name, module?, timedAction?, time?, category?, tags?,
              needToBeLearn?, skillRequired?, xpAward?, onCreate?,
              extra = { "Key = Value", ... },
              inputs  = { { amount, items = "Base.A;Base.B" | tags = "base:x",
                            mode = "keep"|"destroy"|"", flags = "A;B" }
                          | { line = "fluid 0.5 [Water]" }, ... },
              outputs = { { amount, item } | { line = "..." }, ... } }

    REDEFINITION APPENDS. A second `craftRecipe X` block for an existing
    X adds to its input/output lists instead of replacing them, so the draft
    warns when the name is taken by a file other than the one it writes.
    The written file is one recipe per file (media/scripts/recipes/
    <mod>_<name>.txt): rewriting it replaces exactly that recipe.
]]

local try = WB.try

local function clean(s) return (tostring(s or ""):gsub("[\r\n,{}]", " "):gsub("^%s+", ""):gsub("%s+$", "")) end
local function ident(s) return (tostring(s or ""):gsub("[^%w_]", "")) end

local function inputLine(i)
    if i.line and i.line ~= "" then return clean(i.line) end
    local amount = tonumber(i.amount) or 1
    local what
    if i.tags and i.tags ~= "" then what = "tags[" .. clean(i.tags):gsub("%s", "") .. "]"
    else what = "[" .. clean(i.items):gsub("%s", "") .. "]" end
    local s = "item " .. amount .. " " .. what
    if i.mode and i.mode ~= "" then s = s .. " mode:" .. ident(i.mode) end
    if i.flags and i.flags ~= "" then s = s .. " flags[" .. clean(i.flags):gsub("%s", "") .. "]" end
    return s
end

local function outputLine(o)
    if o.line and o.line ~= "" then return clean(o.line) end
    return "item " .. (tonumber(o.amount) or 1) .. " " .. clean(o.item):gsub("%s", "")
end

local function itemsOf(i)
    local out = {}
    if i.line or (i.tags and i.tags ~= "") then return out end
    for t in tostring(i.items or ""):gmatch("[^;%s]+") do
        out[#out + 1] = (t:gsub("^%d+:", ""))   -- "25:Base.Thread_Sinew": a per-item amount
    end
    return out
end

WB.register("recipeDraft", function(a)
    local d = a.draft or a
    local name = ident(d.name)
    if name == "" then error("recipe name is required") end
    local module = ident(d.module ~= nil and d.module ~= "" and d.module or "Base")
    local full = module .. "." .. name
    local L = {}
    local function add(l) L[#L + 1] = l end
    add("/*")
    add("   " .. full .. ": written by the Engine Workbench recipe builder; edit freely.")
    add("   One recipe per file: redefining a craftRecipe elsewhere APPENDS to its lists.")
    add("*/")
    add("module " .. module)
    add("{")
    add("    craftRecipe " .. name)
    add("    {")
    add("        timedAction = " .. ident(d.timedAction ~= "" and d.timedAction or "Making") .. ",")
    add("        time = " .. (tonumber(d.time) or 50) .. ",")
    if d.category and d.category ~= "" then add("        category = " .. clean(d.category) .. ",") end
    add("        Tags = " .. ((d.tags and d.tags ~= "") and clean(d.tags):gsub("%s", "") or "InHandCraft") .. ",")
    if d.needToBeLearn then add("        NeedToBeLearn = true,") end
    if d.skillRequired and d.skillRequired ~= "" then add("        SkillRequired = " .. clean(d.skillRequired):gsub("%s", "") .. ",") end
    if d.xpAward and d.xpAward ~= "" then add("        xpAward = " .. clean(d.xpAward):gsub("%s", "") .. ",") end
    if d.onCreate and d.onCreate ~= "" then add("        OnCreate = " .. clean(d.onCreate) .. ",") end
    for _, x in ipairs(d.extra or {}) do if clean(x) ~= "" then add("        " .. clean(x) .. ",") end end
    add("        inputs")
    add("        {")
    for _, i in ipairs(d.inputs or {}) do add("            " .. inputLine(i) .. ",") end
    add("        }")
    add("        outputs")
    add("        {")
    for _, o in ipairs(d.outputs or {}) do add("            " .. outputLine(o) .. ",") end
    add("        }")
    add("    }")
    add("}")
    add("")

    local warnings = {}
    local sm = ScriptManager.instance
    for n, i in ipairs(d.inputs or {}) do
        for _, t in ipairs(itemsOf(i)) do
            if not try(function() return sm:getItem(t) end) then warnings[#warnings + 1] = "input " .. n .. ": no item " .. t end
        end
        if not i.line and (not i.items or i.items == "") and (not i.tags or i.tags == "") then
            warnings[#warnings + 1] = "input " .. n .. ": no items or tags"
        end
    end
    for n, o in ipairs(d.outputs or {}) do
        if not o.line and o.item and o.item ~= "" and not try(function() return sm:getItem(clean(o.item)) end) then
            warnings[#warnings + 1] = "output " .. n .. ": no item " .. tostring(o.item)
        end
    end
    if #(d.inputs or {}) == 0 then warnings[#warnings + 1] = "no inputs: the recipe can never be crafted" end
    if d.onCreate and d.onCreate ~= "" then
        local fn = _G
        for part in clean(d.onCreate):gmatch("[^%.]+") do fn = type(fn) == "table" and fn[part] or nil end
        if type(fn) ~= "function" then warnings[#warnings + 1] = "OnCreate " .. clean(d.onCreate) .. " is not a loaded function in this VM" end
    end

    local modId = tostring(a.mod or "mod")
    local path = "media/scripts/recipes/" .. (ident(modId) .. "_" .. name):lower() .. ".txt"
    local exists = try(function() return sm:getCraftRecipe(full) end) ~= nil
    return { text = table.concat(L, "\n"), path = path, full = full, exists = exists, warnings = warnings }
end)

-- A craftRecipe block -> draft. Unknown keys are kept as `extra` lines, and
-- input/output lines that are not plain items (fluids, energy, -tags with
-- more options) are kept verbatim as `line`, so a fork round-trips.
WB.register("recipeParse", function(a)
    local text = tostring(a.text or "")
    local d = { name = text:match("craftRecipe%s+([%w_]+)") or "", inputs = {}, outputs = {}, extra = {} }
    local KNOWN = { timedaction = "timedAction", time = "time", category = "category", tags = "tags",
                    needtobelearn = "needToBeLearn", skillrequired = "skillRequired", xpaward = "xpAward", oncreate = "onCreate" }
    local section
    for raw in text:gmatch("[^\n]+") do
        local line = raw:gsub("^%s+", ""):gsub("%s*,?%s*$", "")
        if line:match("^inputs") then section = "inputs"
        elseif line:match("^outputs") then section = "outputs"
        elseif line == "}" then section = nil
        elseif line == "{" or line == "" or line:match("^craftRecipe") then
        elseif section == "inputs" then
            local amount, rest = line:match("^item%s+([%d%.]+)%s+(.*)$")
            local items = rest and rest:match("^%[([^%]]*)%]")
            local tags = rest and rest:match("^tags%[([^%]]*)%]")
            local after = rest and (rest:gsub("^tags%[[^%]]*%]", ""):gsub("^%[[^%]]*%]", ""))
            local mode = after and after:match("mode:(%w+)")
            local flags = after and after:match("flags%[([^%]]*)%]")
            local leftover = after and after:gsub("mode:%w+", ""):gsub("flags%[[^%]]*%]", ""):gsub("%s+", "")
            if amount and (items or tags) and leftover == "" then
                d.inputs[#d.inputs + 1] = { amount = tonumber(amount), items = items, tags = tags, mode = mode or "", flags = flags or "" }
            else
                d.inputs[#d.inputs + 1] = { line = line }
            end
        elseif section == "outputs" then
            local amount, item = line:match("^item%s+([%d%.]+)%s+([%w_%.]+)$")
            if amount then d.outputs[#d.outputs + 1] = { amount = tonumber(amount), item = item }
            else d.outputs[#d.outputs + 1] = { line = line } end
        else
            local k, v = line:match("^([%w_]+)%s*=%s*(.-)$")
            if k and KNOWN[k:lower()] then
                local f = KNOWN[k:lower()]
                if f == "needToBeLearn" then d[f] = v:lower() == "true"
                elseif f == "time" then d[f] = tonumber(v) or v
                else d[f] = v end
            elseif k then
                d.extra[#d.extra + 1] = line
            end
        end
    end
    return d
end)
