--[[
    Craft simulator: run a recipe through the REAL engine path.

    real IsoPlayer (PZEngine.newPlayer) -> inventory filled with real items ->
    HandcraftLogic over that inventory -> VANILLA ISHandcraftAction:performRecipe
    (loaded from the PZ install, with whatever the mod wraps around it after
    OnGameBoot) -> CraftRecipeMonitor for the engine's own account.
    Same chain as VorpallySauced's CraftTransferRealCraftTests.

    Tools: craftPlan{recipe}  craft{recipe, items, qualify, mode}  craftReset{}
]]

local try = WB.try
local function s(v) if v == nil then return nil end return tostring(v) end
local compile = _pz_compile or loadstring

local C = WB.craft or {}
WB.craft = C

local function need()
    if not (PZEngine and PZEngine.available()) then
        error("engine unavailable in this mod context - pick a mod with engine = true")
    end
    if not (PZEngine.newPlayer and PZEngine.loadVanilla) then
        error("this kit's PZEngine has no newPlayer/loadVanilla (needs kit f0aef52+)")
    end
end

-- One player per VM; vanilla performRecipe + the mod's hooks installed once.
function C.setup()
    if C.player then return C.player end
    if C.setupErr then error(C.setupErr) end
    local p, err = PZEngine.newPlayer()
    if not p then C.setupErr = "newPlayer: " .. tostring(err); error(C.setupErr) end
    ISHandcraftAction = nil
    if not Actions then
        local ok, e = PZEngine.loadVanilla("shared/ActionManager")
        if not ok then C.setupErr = "ActionManager: " .. tostring(e); error(C.setupErr) end
    end
    local ok, e = PZEngine.loadVanilla("shared/Entity/TimedActions/ISHandcraftAction")
    if not ok then C.setupErr = "ISHandcraftAction: " .. tostring(e); error(C.setupErr) end
    C.vanillaPerform = ISHandcraftAction.performRecipe
    -- Vanilla files that timed actions reach and that mods hook from
    -- OnGameBoot (VPS ReloadSpeedHook wraps ISReloadWeaponAction): load
    -- them BEFORE the boot listeners fire, as the game does. Best effort.
    for _, f in ipairs({ "shared/Logs/ISLogSystem", "shared/TimedActions/ISReloadWeaponAction" }) do
        pcall(PZEngine.loadVanilla, f)
    end
    -- Mods install their performRecipe wrappers from OnGameBoot (deferred so
    -- vanilla is defined first) — fire it once, as the game does.
    local fired = 0
    if Events and Events.OnGameBoot and Events.OnGameBoot._listeners then
        for _, fn in ipairs(Events.OnGameBoot._listeners) do pcall(fn); fired = fired + 1 end
    end
    C.hooked = ISHandcraftAction.performRecipe ~= C.vanillaPerform
    C.bootListeners = fired
    C.player = p
    C.ground(p)
    return p
end

-- Stand the craft player on a real square. Outputs too heavy to carry go
-- through vanilla Actions.addOrDropItem, which drops them at the player's
-- feet (character:getCurrentSquare()); with no square that is a nil index
-- (Cast Blacksmith Anvil). Best effort: kits without newSquare skip it.
function C.ground(p)
    if C.square or not PZEngine.newSquare then return C.square end
    local sq = PZEngine.newSquare(240, 240, 0)   -- harness squares are 0..255
    if not sq then return nil end
    p:setCurrent(sq)
    p:setX(sq:getX() + 0.5)
    p:setY(sq:getY() + 0.5)
    C.square = sq
    return sq
end

-- A plain table on the craft square: the surface an AnySurfaceCraft recipe is
-- crafted on. No entity; the engine only checks it exists and is in range.
function C.surface()
    if C.surfaceObj then return C.surfaceObj end
    local sq = C.square or C.ground(C.setup())
    if not sq then return nil end
    C.surfaceObj = IsoObject.new(sq, "furniture_tables_high_01_0", "Table")
    return C.surfaceObj
end

-- A workstation: the tile object a CraftBench entity lives on, built once per
-- entity script on the craft square. The game builds these from map data
-- (GameEntityFactory.CreateIsoEntityFromCellLoading); here the script is
-- known, so CreateIsoObjectEntity builds it directly. Only a multi-square
-- MASTER tile gets CraftBench/UiConfig, and SpriteConfig finds the tile by
-- sprite name, hence PZEngine.initSpriteConfigs (once) and the entity's own
-- first sprite.
function C.workstation(name, sprite)
    C.benches = C.benches or {}
    if C.benches[name] then return C.benches[name] end
    if not (PZEngine.initSpriteConfigs and GameEntityFactory and ComponentType) then
        return nil, "this kit's engine bridge cannot build entities (needs initSpriteConfigs + GameEntityFactory exposed)"
    end
    if C.spriteConfigs == nil then
        local n, err = PZEngine.initSpriteConfigs()
        C.spriteConfigs = n or false
        if not n then return nil, "initSpriteConfigs: " .. tostring(err) end
    end
    local es = getScriptManager():getGameEntityScript(name)
    if not es then return nil, "no entity script " .. tostring(name) end
    if not sprite then return nil, "entity has no SpriteConfig sprite" end
    local sq = C.square or C.ground(C.setup())
    if not sq then return nil, "no harness square" end
    local obj = IsoObject.new(sq, sprite, name)
    GameEntityFactory.CreateIsoObjectEntity(obj, es, true)
    local bench = obj:getComponent(ComponentType.CraftBench)
    if not bench then return nil, "built " .. name .. " on " .. sprite .. " but it has no CraftBench (not the master tile?)" end
    local w = { obj = obj, bench = bench, name = name, sprite = sprite }
    C.benches[name] = w
    return w
end

WB.register("craftReset", function()
    C.player, C.setupErr = nil, nil
    return { ok = true }
end)

-- Item descriptor for results.
local function itemInfo(it)
    local md = try(function() return it:getModData() end)
    local mdCopy
    if type(md) == "table" then
        for _ in pairs(md) do mdCopy = md; break end   -- Kahlua has no `next`
    end
    return {
        ref = WB.ref(it),
        fullType = s(try(function() return it:getFullType() end)),
        name = s(try(function() return it:getDisplayName() end)) or s(try(function() return it:getName() end)),
        id = try(function() return it:getID() end),
        condition = try(function() return it:getCondition() end),
        conditionMax = try(function() return it:getConditionMax() end),
        uses = try(function() return it:getCurrentUses() end),
        class = WB.className(it),
        onFloor = try(function() return it:getWorldItem() ~= nil end) or false,
        modData = mdCopy,
    }
end
C.itemInfo = itemInfo

-- Suggested starting inventory: for each Item input, its first possible item
-- at the listed amount. Tools/keep inputs included (the craft needs them).
WB.register("craftPlan", function(a)
    need()
    local r = WB.findRecipe(a.recipe)
    if not r then error("no craft recipe " .. tostring(a.recipe)) end
    local plan, notes = {}, {}
    for i, input in ipairs(WB.list(r:getInputs())) do
        local rt = s(try(function() return input:getResourceType() end))
        if rt == "Item" then
            local items = WB.list(try(function() return input:getPossibleInputItems() end))
            local first = items[1] and s(items[1]:getFullName())
            if first then
                local n = WB.itemsForAmount(first, try(function() return input:getIntAmount(first) end)
                                                  or try(function() return input:getIntAmount() end) or 1)
                plan[#plan + 1] = { type = first, count = n, input = i - 1,
                                    keep = try(function() return input:isKeep() end) or false,
                                    alternatives = #items }
            else
                notes[#notes + 1] = "input " .. (i - 1) .. ": no possible items"
            end
        else
            notes[#notes + 1] = "input " .. (i - 1) .. " is a " .. tostring(rt) .. " input - the simulator fills Item inputs only"
        end
    end
    return { recipe = a.recipe, items = plan, notes = notes }
end)

local function runInit(src, it)
    if not src or src == "" then return nil end
    local chunk, err = compile("local it = ...\n" .. src, "item init")
    if not chunk then return "init compile: " .. tostring(err) end
    local ok, e = pcall(chunk, it)
    if not ok then return "init: " .. tostring(e) end
    return nil
end

local function setModData(it, tbl)
    if type(tbl) ~= "table" then return end
    local md = it:getModData()
    for k, v in pairs(tbl) do md[k] = v end
end

-- args: recipe, items = { {type, count, modData?, init?} }, qualify (default
-- true), mode = "action" (vanilla performRecipe, mod hooks run) | "logic"
-- (HandcraftLogic:performCurrentRecipe only, no Lua action layer)
WB.register("craft", function(a)
    need()
    local p = C.setup()
    local recipe = WB.findRecipe(a.recipe)
    if not recipe then error("no craft recipe " .. tostring(a.recipe)) end
    local inv = p:getInventory()
    inv:removeAllItems()

    local initErrors, placed, bySlot, allPinned = {}, {}, {}, #(a.items or {}) > 0
    for _, spec in ipairs(a.items or {}) do
        if spec.input == nil then allPinned = false end
        -- spec.ref: an EXISTING live item (a previous craft's output, a board
        -- card), so chains run on the same engine objects. Otherwise mint
        -- spec.count fresh items of spec.type.
        local fromRef = spec.ref and WB.deref(spec.ref)
        if spec.ref and not fromRef then
            initErrors[#initErrors + 1] = "ref $" .. tostring(spec.ref) .. " is gone (VM restarted?) - replay the board"
        end
        for _ = 1, (fromRef and 1) or (spec.ref and 0) or math.max(1, tonumber(spec.count) or 1) do
            local it = fromRef or PZEngine.instanceItem(spec.type)
            if not it then
                initErrors[#initErrors + 1] = "unknown item " .. tostring(spec.type)
                break
            end
            if not fromRef then setModData(it, spec.modData) end
            local e = (not fromRef) and runInit(spec.init, it) or nil
            if e then initErrors[#initErrors + 1] = spec.type .. ": " .. e end
            -- Addon prep steps (40_addons.lua), e.g. vps/addKills: the
            -- mod's own code shapes the input, not hand-written modData.
            if spec.steps and WB.addonPrep and not fromRef then
                for _, pe in ipairs(WB.addonPrep(it, spec.steps, p)) do
                    initErrors[#initErrors + 1] = spec.type .. ": " .. pe
                end
            end
            -- An earlier output that was dropped at the player's feet: pick it
            -- back up first, as a player would.
            local wi = fromRef and it:getWorldItem()
            if wi then
                pcall(function() wi:getSquare():transmitRemoveItemFromSquare(wi) end)
                pcall(function() it:setWorldItem(nil) end)
            end
            inv:AddItem(it)
            placed[#placed + 1] = it
            if spec.input ~= nil then
                local list = bySlot[spec.input] or {}
                bySlot[spec.input] = list
                list[#list + 1] = it
            end
        end
    end
    if #initErrors > 0 and a.strict then return { ok = false, err = table.concat(initErrors, "\n") } end

    local qualified = {}
    if a.qualify ~= false then
        if try(function() return recipe:needToBeLearn() end) and not p:isRecipeKnown(recipe, true) then
            p:getKnownRecipes():add(recipe:getName())
            qualified[#qualified + 1] = "learned " .. s(recipe:getName())
        end
        for i = 0, recipe:getRequiredSkillCount() - 1 do
            local req = recipe:getRequiredSkill(i)
            p:setPerkLevelDebug(req:getPerk(), req:getLevel())
            qualified[#qualified + 1] = s(req:getPerk()) .. " " .. s(req:getLevel())
        end
    end

    -- Addon panels BEFORE the craft: a consumed input's soul is the thing
    -- a transfer hook is supposed to carry over, so show it as it was.
    local panelsBefore = {}
    if WB.addonPanelsFor then
        for _, it in ipairs(placed) do panelsBefore[it] = WB.addonPanelsFor(it) end
    end

    -- a.bench = { name, sprite } (the server picks it from the recipe's tags):
    -- craft at that workstation, as its entity window does in game.
    local bench, benchObj, workstation
    if type(a.bench) == "table" and a.bench.name then
        local w, werr = C.workstation(a.bench.name, a.bench.sprite)
        workstation = { name = a.bench.name, sprite = a.bench.sprite, ok = w ~= nil, err = werr }
        if w then bench, benchObj = w.bench, w.obj
        else
            -- A bench that was asked for and could not be built is a failed
            -- craft, never a quiet craft in hand: for a recipe that also works
            -- in hand that fallback PASSED (the Charcoal_Pit 'false' tile).
            return { ok = false, ran = false, recipe = s(recipe:getName()), workstation = workstation,
                     err = "workstation " .. a.bench.name .. " (" .. tostring(a.bench.sprite) .. ") could not be built: "
                         .. tostring(werr) .. " -- nothing was crafted",
                     consumed = {}, kept = {}, outputs = {}, why = {}, initErrors = initErrors }
        end
    end
    -- AnySurfaceCraft (dismantle/assemble and many more): HandcraftLogic
    -- refuses unless its isoObject is within 3 tiles
    -- (isCharacterInRangeOfWorkbench), i.e. the table you craft on in game.
    -- Stand at one. a.surface = false crafts with none (the game refuses).
    if not benchObj and a.surface ~= false and (try(function() return recipe:isAnySurfaceCraft() end) or false) then
        benchObj = C.surface()
        if benchObj then workstation = { name = "a table", surface = true, ok = true } end
    end
    local logic = HandcraftLogic.new(p, bench, benchObj)
    local containers = ArrayList.new(); containers:add(inv)
    logic:setContainers(containers)
    logic:setRecipe(recipe)
    -- Every spec pinned to an input (spec.input = 0-based index into
    -- getInputs()): fill them manually, the way vanilla's ISHandcraftAction
    -- does from the crafting window. Otherwise the engine auto-fills from the
    -- inventory, and an item that fits two inputs (a hammer that is both the
    -- tool and the thing dismantled) can land in either.
    local manual
    if allPinned then
        manual = { ok = true }
        logic:setManualSelectInputs(true)
        logic:clearManualInputs()
        local inputs = WB.list(recipe:getInputs())
        for idx, list in pairs(bySlot) do
            local al = ArrayList.new()
            for _, it in ipairs(list) do al:add(it) end
            local script = inputs[idx + 1]
            if not (script and logic:setManualInputsFor(script, al)) then
                manual.ok = false
                initErrors[#initErrors + 1] = "input " .. idx .. ": the engine refused the manual items"
            end
        end
    end
    -- a.monitor: flip Core.debug so CraftRecipeMonitor records the engine's
    -- own account. OFF by default: under Core.debug any Lua error raised
    -- during the craft goes to UIManager.debugBreakpoint, which pcalls on
    -- LuaManager.debugthread -- null headless -- so a normally-swallowed
    -- error becomes a fatal NPE mid-craft (after inputs are consumed).
    -- The game and VPS's real-craft tests run with debug off.
    local monitor, prevDebug
    if a.monitor then
        prevDebug = PZEngine.setCoreDebug(true)
        monitor = CraftRecipeMonitor.Create()
        logic:getRecipeData():setMonitor(monitor)
    end

    -- Server-side context, network calls recorded instead of sent.
    local cmds = {}
    local saved = { isClient, isServer, sendAddItemToContainer, sendRemoveItemFromContainer, sendServerCommand }
    isClient = function() return false end
    isServer = function() return true end
    sendAddItemToContainer = function() end
    sendRemoveItemFromContainer = function() end
    sendServerCommand = function(x, y, z, w)
        if type(x) == "string" then cmds[#cmds + 1] = { module = x, command = y, args = z }
        else cmds[#cmds + 1] = { module = y, command = z, args = w } end
    end
    -- Hook tracing: wrap every Lua hook the recipe declares so the result
    -- says whether the engine called it, with what, and what it threw.
    -- Engine->Lua calls resolve the name through LuaManager.getFunctionObject
    -- against this env at call time, so a temporary wrapper is what it sees.
    local hookLog, restores = {}, {}
    for _, h in ipairs(a.hooks or {}) do
        local rec = { kind = h.kind, fn = h.fn, calls = 0 }
        hookLog[#hookLog + 1] = rec
        local parts = {}
        for seg in tostring(h.fn):gmatch("[^%.]+") do parts[#parts + 1] = seg end
        local leaf = parts[#parts]
        local function resolve()
            local parent = _G
            for i = 1, #parts - 1 do
                parent = type(parent) == "table" and rawget(parent, parts[i]) or nil
            end
            return parent, type(parent) == "table" and parent[leaf] or nil
        end
        local parent, fn = resolve()
        -- In game every mod file is loaded; here only required ones are.
        -- Load the file(s) the server found defining this hook's table.
        if type(fn) ~= "function" and h.requires then
            rec.loaded = {}
            for _, req in ipairs(h.requires) do
                local okr, er = pcall(require, req)
                rec.loaded[#rec.loaded + 1] = okr and req or (req .. " (" .. tostring(er) .. ")")
            end
            parent, fn = resolve()
        end
        if type(fn) ~= "function" then
            rec.resolved = false
            local root = rawget(_G, parts[1])
            rec.reason = root == nil
                and (parts[1] .. " is not defined in this VM - in 42.21 vanilla RecipeCode*/ItemCode* are Java classes the engine bridge does not expose, so the engine will find no hook")
                or (h.fn .. " is not a Lua function here")
        else
            rec.resolved = true
            restores[#restores + 1] = function() parent[leaf] = fn end
            parent[leaf] = function(...)
                rec.calls = rec.calls + 1
                local args = { ... }
                local shown = {}
                for i = 1, select("#", ...) do
                    local v = args[i]
                    local t = type(v)
                    shown[i] = (t == "number" or t == "boolean" or t == "string") and v or (v == nil and "nil" or WB.describe(v))
                end
                rec.args = shown
                local res = { pcall(fn, ...) }
                if not res[1] then rec.err = tostring(res[2]); error(res[2]) end
                local r1 = res[2]
                if r1 ~= nil then
                    local t = type(r1)
                    rec.returned = (t == "number" or t == "boolean" or t == "string") and r1 or WB.describe(r1)
                end
                return unpack(res, 2)
            end
        end
    end

    local canPerform = try(function() return logic:canPerformCurrentRecipe() end) or false
    local needsStation = try(function() return recipe:requiresSpecificWorkstation() end) or false
    local atStation = needsStation and (try(function() return logic:hasRequiredWorkstation() end) or false) or nil
    -- The game gates the craft on canPerformCurrentRecipe (inputs, skills,
    -- the workstation) before any action starts; performRecipe itself checks
    -- none of it. a.enforce = refuse here as the game would.
    local gated = a.enforce and not canPerform
    local t0 = _pz_now_ms and _pz_now_ms() or nil
    local ok, err, trace
    if gated then
        ok = true
    elseif a.mode == "logic" then
        ok, err, trace = pcall(function() return logic:performCurrentRecipe() end)
    else
        ok, err, trace = pcall(ISHandcraftAction.performRecipe, { character = p, logic = logic })
    end
    local ms = t0 and (_pz_now_ms() - t0) or nil
    isClient, isServer, sendAddItemToContainer, sendRemoveItemFromContainer, sendServerCommand =
        saved[1], saved[2], saved[3], saved[4], saved[5]
    if a.monitor then PZEngine.setCoreDebug(prevDebug) end
    for _, undo in ipairs(restores) do undo() end

    local outs = ArrayList.new()
    pcall(function() logic:getCreatedOutputItems(outs) end)
    local outputs, outSet = {}, {}
    local function withPanels(it)
        local info = itemInfo(it)
        if WB.addonPanelsFor then
            info.panelsBefore = panelsBefore[it]
            info.panels = WB.addonPanelsFor(it)
            info.badges = WB.addonBadges and WB.addonBadges(it) or nil
            info.visual = WB.addonVisual and WB.addonVisual(it) or nil
        end
        return info
    end
    for _, it in ipairs(WB.list(outs)) do outputs[#outputs + 1] = withPanels(it); outSet[it] = true end

    local after, still = {}, {}
    for _, it in ipairs(WB.list(inv:getItems())) do
        after[#after + 1] = itemInfo(it)
        still[it] = true
    end
    local consumed, kept = {}, {}
    for _, it in ipairs(placed) do
        if still[it] then kept[#kept + 1] = withPanels(it) else consumed[#consumed + 1] = withPanels(it) end
    end

    local lines, why = {}, {}
    for _, l in ipairs(monitor and WB.list(monitor:GetLines()) or {}) do
        l = tostring(l)
        lines[#lines + 1] = l
        if l:find("WARN") or l:find("FAIL") or l:find("NOT ") then why[#why + 1] = l end
    end

    local errMsg
    if not ok then
        errMsg = tostring(err) .. (trace and ("\n" .. tostring(trace)) or "")
        if a.monitor and errMsg:find('"thread" is null', 1, true) then
            errMsg = errMsg .. "\n\n(Core.debug was on for the monitor: a Lua error raised during this craft was routed to PZ's debugger, "
                .. "which has no thread headless. Craft again with the monitor off to see what the game does.)"
        end
    end
    -- A recipe with no outputs block (scrap jewellery, sharpen a blade,
    -- burn a page) succeeds by running: requiring outputs would make every
    -- one of them read as refused on the board and in blueprint tests.
    local declared = try(function() return recipe:getOutputs():size() end) or 0
    local success = ok and (#outputs > 0 or declared == 0) and not gated
    -- Without enforce the recipe runs even where the game would refuse it
    -- (to show what WOULD happen). Say so: ran + consumed alone read as
    -- "it works", and canPerform is the game's actual verdict.
    local wouldRefuse = (not a.enforce) and not canPerform
    -- ok answers "would the game craft this"; `ran` says what was executed.
    if wouldRefuse then success = false end
    if wouldRefuse then
        why[#why + 1] = "the game would REFUSE this craft (canPerformCurrentRecipe = false); it ran only because enforce is off"
    end
    return {
        ok = success, ran = ok, err = errMsg, ms = ms,
        recipe = s(recipe:getName()), mode = a.mode or "action",
        hooked = C.hooked, canPerform = canPerform, hooks = hookLog,
        qualified = qualified, initErrors = initErrors, manualInputs = manual and manual.ok or false,
        workstation = workstation, needsWorkstation = needsStation, atWorkstation = atStation, gated = gated or nil,
        wouldRefuse = wouldRefuse or nil,
        consumed = consumed, kept = kept, outputs = outputs, inventory = after,
        commands = cmds, monitor = lines, why = why, monitored = a.monitor and true or false,
        logic = WB.describe(logic), player = WB.describe(p),
    }
end)
