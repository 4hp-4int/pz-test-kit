--[[
    Script browser: items, craft recipes, fixing, evolved recipes - read from
    the REAL ScriptManager the engine parsed (vanilla + this mod's scripts).

    Tools:  items{q,limit}  item{fullType}  recipes{q,item,limit}  recipe{name}
            fixing{q}  evolved{q}  scriptStats{}
]]

local function sm() return getScriptManager() end
local function need()
    if not (PZEngine and PZEngine.available()) then
        error("engine unavailable in this mod context (" .. tostring(PZEngine and PZEngine.bootError and PZEngine.bootError()) .. ") - pick a mod with engine = true")
    end
end
local try = WB.try
local function s(v) if v == nil then return nil end return tostring(v) end

-- ── caches (built once per VM; scripts don't change under a resident VM) ──
local cache = {}
WB.scriptCaches = WB.scriptCaches or {}
WB.scriptCaches[#WB.scriptCaches + 1] = cache   -- cleared after a script reload (70_dev.lua)

local function allItems()
    if cache.items then return cache.items end
    local out = {}
    for _, it in ipairs(WB.list(sm():getAllItems())) do
        out[#out + 1] = {
            fullType = s(it:getFullName()),
            name = s(try(function() return it:getDisplayName() end)) or s(it:getName()),
            type = s(try(function() return it:getItemType() end)) or s(try(function() return it:getTypeString() end)),
            category = s(try(function() return it:getDisplayCategory() end)),
            obj = it,
        }
    end
    table.sort(out, function(a, b) return a.fullType < b.fullType end)
    cache.items = out
    return out
end

local function inputItems(input)
    local out = {}
    local list = try(function() return input:getPossibleInputItems() end)
    if list then for _, it in ipairs(WB.list(list)) do out[#out + 1] = s(it:getFullName()) end end
    return out
end
local function outputItems(output)
    local out = {}
    local list = try(function() return output:getPossibleResultItems() end)
    if list then for _, it in ipairs(WB.list(list)) do out[#out + 1] = s(it:getFullName()) end end
    return out
end

-- recipe name -> {consumes=set, keeps=set, produces=set}; item -> recipe lists
local function recipeIndex()
    if cache.ridx then return cache.ridx end
    local byItem = {}     -- fullType -> { consumedBy = {}, keptBy = {}, producedBy = {} }
    local list = {}
    local function slot(t)
        local e = byItem[t]
        if not e then e = { consumedBy = {}, keptBy = {}, producedBy = {} }; byItem[t] = e end
        return e
    end
    for _, r in ipairs(WB.list(sm():getAllCraftRecipes())) do
        local name = s(r:getName())
        local mod = s(try(function() return r:getModule():getName() end)) or "Base"
        local rec = { name = name, module = mod, full = mod .. "." .. name,
                      label = s(try(function() return r:getTranslationName() end)) or name,
                      category = s(try(function() return r:getCategory() end)),
                      learn = try(function() return r:needToBeLearn() end) or false,
                      items = {}, obj = r }
        for _, input in ipairs(WB.list(r:getInputs())) do
            local keep = try(function() return input:isKeep() end)
            for _, t in ipairs(inputItems(input)) do
                rec.items[t] = true
                local e = slot(t)
                local bucket = keep and e.keptBy or e.consumedBy
                bucket[#bucket + 1] = rec.full
            end
        end
        -- OutputScript is not Lua-exposed in engine mode, so outputs come
        -- from the script source the server parsed (WB.scriptOutputs).
        local produced = {}
        for _, output in ipairs(WB.list(r:getOutputs())) do
            for _, t in ipairs(outputItems(output)) do produced[#produced + 1] = t end
        end
        if #produced == 0 and WB.scriptOutputs then produced = WB.scriptOutputs[rec.full] or {} end
        for _, t in ipairs(produced) do
            rec.items[t] = true
            local e = slot(t)
            e.producedBy[#e.producedBy + 1] = rec.full
        end
        list[#list + 1] = rec
    end
    table.sort(list, function(a, b) return a.full < b.full end)
    cache.ridx = { list = list, byItem = byItem }
    return cache.ridx
end

local function matches(q, ...)
    if q == nil or q == "" then return true end
    q = q:lower()
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if v and tostring(v):lower():find(q, 1, true) then return true end
    end
    return false
end

-- ── tools ─────────────────────────────────────────────────────────────────
WB.register("scriptStats", function()
    need()
    local fixing = try(function() return sm():getAllFixing(ArrayList.new()) end)
    return {
        items = #allItems(),
        recipes = #recipeIndex().list,
        fixing = fixing and fixing:size() or nil,
        evolved = try(function() return sm():getAllEvolvedRecipesList():size() end),
        vehicles = try(function() return sm():getAllVehicleScripts():size() end),
    }
end)

WB.register("items", function(a)
    need()
    local out, limit = {}, tonumber(a.limit) or 200
    local total = 0
    for _, it in ipairs(allItems()) do
        if matches(a.q, it.fullType, it.name, it.type, it.category) then
            total = total + 1
            if #out < limit then
                out[#out + 1] = { fullType = it.fullType, name = it.name, type = it.type, category = it.category }
            end
        end
    end
    return { total = total, items = out }
end)

-- Script-level properties: every zero-arg getter the Item script answers.
local ITEM_SCRIPT_SKIP = { getModData = true, getClass = true }
WB.register("item", function(a)
    need()
    local script = sm():getItem(a.fullType)
    if not script then error("no item script " .. tostring(a.fullType)) end
    local props = {}
    for _, m in ipairs(WB.methodsOf(script)) do
        if (m:match("^get%u") or m:match("^is%u") or m:match("^has%u") or m:match("^can%u")) and not ITEM_SCRIPT_SKIP[m] then
            local ok, v = pcall(function() return script[m](script) end)
            if ok and v ~= nil then
                local t = type(v)
                if t == "number" or t == "boolean" or t == "string" then props[m] = v
                else props[m] = WB.describe(v) end
            end
        end
    end
    local links = recipeIndex().byItem[a.fullType] or { consumedBy = {}, keptBy = {}, producedBy = {} }
    local tags = {}
    local tl = try(function() return script:getTags() end)
    if tl then for _, t in ipairs(WB.list(tl)) do tags[#tags + 1] = s(t) end end
    return {
        fullType = a.fullType,
        script = WB.describe(script),
        props = props,
        tags = tags,
        consumedBy = links.consumedBy, keptBy = links.keptBy, producedBy = links.producedBy,
    }
end)

WB.register("recipes", function(a)
    need()
    local out, limit, total = {}, tonumber(a.limit) or 300, 0
    for _, r in ipairs(recipeIndex().list) do
        if (not a.item or r.items[a.item]) and matches(a.q, r.full, r.label, r.category) then
            total = total + 1
            if #out < limit then
                out[#out + 1] = { name = r.name, module = r.module, full = r.full, label = r.label,
                                  category = r.category, learn = r.learn }
            end
        end
    end
    return { total = total, recipes = out }
end)

local function findRecipe(name)
    if not name then return nil end
    local r = sm():getCraftRecipe(name)
    if r then return r end
    if not name:find("%.") then return sm():getCraftRecipe("Base." .. name) end
    return nil
end
WB.findRecipe = findRecipe

local function ioLine(io)
    return s(try(function() return io:getOriginalLine() end))
end

WB.register("recipe", function(a)
    need()
    local r = findRecipe(a.name)
    if not r then error("no craft recipe " .. tostring(a.name)) end
    local inputs = {}
    for i, input in ipairs(WB.list(r:getInputs())) do
        local items = inputItems(input)
        inputs[i] = {
            index = i - 1,
            line = ioLine(input),
            resource = s(try(function() return input:getResourceType() end)),
            amount = try(function() return input:getAmount() end),
            -- items needed (amount is in uses; drainables hold several)
            itemsNeeded = items[1] and WB.itemsForAmount(items[1], try(function() return input:getIntAmount() end) or 1) or nil,
            intAmount = try(function() return input:getIntAmount() end),
            keep = try(function() return input:isKeep() end) or false,
            tool = try(function() return input:isTool() end) or false,
            anyItem = try(function() return input:isAcceptsAnyItem() end) or false,
            items = items,
            obj = WB.describe(input),
        }
    end
    local outputs = {}
    for i, output in ipairs(WB.list(r:getOutputs())) do
        outputs[i] = {
            index = i - 1,
            line = ioLine(output),
            resource = s(try(function() return output:getResourceType() end)),
            amount = try(function() return output:getAmount() end),
            chance = try(function() return output:getChance() end),
            items = outputItems(output),
            obj = WB.describe(output),
        }
    end
    local skills = {}
    for i = 0, (try(function() return r:getRequiredSkillCount() end) or 0) - 1 do
        local req = r:getRequiredSkill(i)
        skills[#skills + 1] = { perk = s(try(function() return req:getPerk() end)), level = try(function() return req:getLevel() end) }
    end
    local xp = {}
    for i = 0, (try(function() return r:getXPAwardCount() end) or 0) - 1 do
        local x = r:getXPAward(i)
        xp[#xp + 1] = { perk = s(try(function() return x:getPerk() end)), amount = try(function() return x:getAmount() end) }
    end
    local tags = {}
    local tl = try(function() return r:getTags() end)
    if tl then for _, t in ipairs(WB.list(tl)) do tags[#tags + 1] = s(t) end end
    local mod = s(try(function() return r:getModule():getName() end)) or "Base"
    return {
        name = s(r:getName()), module = mod, full = mod .. "." .. s(r:getName()),
        label = s(try(function() return r:getTranslationName() end)),
        category = s(try(function() return r:getCategory() end)),
        time = try(function() return r:getTime() end),
        learn = try(function() return r:needToBeLearn() end) or false,
        dark = try(function() return r:canBeDoneInDark() end),
        canWalk = try(function() return r:isCanWalk() end),
        skills = skills, xp = xp, tags = tags,
        inputs = inputs, outputs = outputs,
        obj = WB.describe(r),
    }
end)

WB.register("fixing", function(a)
    need()
    local out = {}
    for _, f in ipairs(WB.list(sm():getAllFixing(ArrayList.new()))) do
        local name = s(try(function() return f:getName() end))
        local req = {}
        local rl = try(function() return f:getRequiredItem() end)
        if rl then for _, x in ipairs(WB.list(rl)) do req[#req + 1] = s(x) end end
        if matches(a.q, name, table.concat(req, " ")) then
            out[#out + 1] = { name = name, require = req, obj = WB.describe(f) }
        end
        if #out >= 300 then break end
    end
    return { fixing = out }
end)

WB.register("evolved", function(a)
    need()
    local out = {}
    for _, e in ipairs(WB.list(sm():getAllEvolvedRecipesList())) do
        local name = s(try(function() return e:getName() end))
        local base = s(try(function() return e:getBaseItem() end))
        local result = s(try(function() return e:getResultItem() end))
        if matches(a.q, name, base, result) then
            out[#out + 1] = { name = name, baseItem = base, resultItem = result, obj = WB.describe(e) }
        end
        if #out >= 300 then break end
    end
    return { evolved = out }
end)
