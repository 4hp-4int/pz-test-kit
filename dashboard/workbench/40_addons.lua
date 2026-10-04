--[[
    Workbench addons: mod-owned item tooling.

    An addon is ONE declarative call. The browser builds every form from it,
    so adding an action is one Lua function, no HTML:

        WB.addon {
            id = "vps", name = "VorpallySauced",
            requires = { "VorpallySauced/WeaponData" },      -- required at load; failure disables the addon (reason shown)
            appliesTo = function(item) return true end,     -- default filter for this addon's actions/panels
            panels = {                                       -- read-only views, shown wherever an item is shown
                { id = "soul", title = "Soul", render = function(item) return { kills = 3 } end },
            },
            actions = {                                      -- buttons on a live item / prep steps on craft inputs
                { id = "addKills", label = "Add kills", doc = "...",
                  params = { { name = "kills", type = "number", default = 50 } },
                  run = function(item, params, ctx) return "message or table" end },
            },
            presets = {                                      -- one-click step lists for craft inputs
                { label = "Blooded", steps = { { "progressTo", { tier = "bonding" } } } },
            },
        }

    param types: number | string | bool | select (options = {...}) | json
    ctx: { player = the workbench's real IsoPlayer, log = function(msg) }

    Where addons come from (loaded after the kit tools, each file isolated so
    one broken addon can't take the others down):
        dashboard/workbench/addons/*.lua           kit-wide (generic)
        <mod root>/workbench/*.lua                 the selected mod
        <dependency root>/workbench/*.lua          its pz-test.lua dependencies
    The mod-root folder sits OUTSIDE media/, so deploy.ps1 never ships it.

    Actions run in a server context (isServer true, isClient false) with
    network calls recorded, same as the craft simulator: progression code is
    server-authoritative in MP, and the recorded commands are part of the
    answer.

    Tools: addons{type?}  addonRun{ref|type, addon, action, params}  addonPanels{ref}
    Lua helpers for other tools: WB.addonPrep(item, steps, player), WB.addonPanelsFor(item)
]]

local try = WB.try

WB.addons = WB.addons or {}
WB.addonOrder = WB.addonOrder or {}
WB.addonLoadErrors = WB.addonLoadErrors or {}

local function check(fn, item)
    if type(fn) ~= "function" then return true end
    local ok, r = pcall(fn, item)
    return ok and r and true or false
end

function WB.addon(def)
    if type(def) ~= "table" or type(def.id) ~= "string" then error("WB.addon: needs a table with a string id") end
    def.name = def.name or def.id
    def.actions = def.actions or {}
    def.panels = def.panels or {}
    def.presets = def.presets or {}
    def.file = WB.currentAddonFile
    for _, req in ipairs(def.requires or {}) do
        local ok, e = pcall(require, req)
        if not ok then
            def.disabled = "require " .. tostring(req) .. " failed: " .. tostring(e)
            break
        end
    end
    if not WB.addons[def.id] then WB.addonOrder[#WB.addonOrder + 1] = def.id end
    WB.addons[def.id] = def
    return def
end

function WB.addonLoadError(file, msg)
    WB.addonLoadErrors[#WB.addonLoadErrors + 1] = { file = file, error = msg }
end

local function findAction(addonId, actionId)
    local a = WB.addons[addonId]
    if not a then error("no addon " .. tostring(addonId)) end
    if a.disabled then error(a.name .. " is disabled: " .. a.disabled) end
    for _, act in ipairs(a.actions) do
        if act.id == actionId then return a, act end
    end
    error(a.name .. " has no action " .. tostring(actionId))
end

-- Fill missing params from declared defaults, coerce types.
local function normParams(act, given)
    local p = {}
    for k, v in pairs(given or {}) do p[k] = v end
    for _, spec in ipairs(act.params or {}) do
        local v = p[spec.name]
        if v == nil or v == "" then v = spec.default end
        if spec.type == "number" and v ~= nil then v = tonumber(v) end
        if spec.type == "bool" then v = v == true or v == "true" end
        p[spec.name] = v
    end
    return p
end

-- Run fn in a server context, recording network calls. Returns ok, result|err, cmds.
function WB.serverContext(fn)
    local cmds = {}
    local saved = { isClient, isServer, sendAddItemToContainer, sendRemoveItemFromContainer, sendServerCommand, sendClientCommand }
    isClient = function() return false end
    isServer = function() return true end
    sendAddItemToContainer = function() end
    sendRemoveItemFromContainer = function() end
    sendServerCommand = function(x, y, z, w)
        if type(x) == "string" then cmds[#cmds + 1] = { module = x, command = y, args = z }
        else cmds[#cmds + 1] = { module = y, command = z, args = w } end
    end
    sendClientCommand = function(_, m, c, a) cmds[#cmds + 1] = { module = m, command = c, args = a, toServer = true } end
    local ok, res, trace = pcall(fn)
    isClient, isServer, sendAddItemToContainer, sendRemoveItemFromContainer, sendServerCommand, sendClientCommand =
        saved[1], saved[2], saved[3], saved[4], saved[5], saved[6]
    if not ok and trace then res = tostring(res) .. "\n" .. tostring(trace) end
    return ok, res, cmds
end

local function playerFor(ctxPlayer)
    if ctxPlayer then return ctxPlayer end
    if WB.craft and WB.craft.setup then
        local ok, p = pcall(WB.craft.setup)
        if ok then return p end
    end
    return nil
end

-- Run one action on a live item. Returns { ok, result, err, log, commands }.
function WB.runAddonAction(item, addonId, actionId, params, player)
    local a, act = findAction(addonId, actionId)
    if not check(act.appliesTo or a.appliesTo, item) then
        return { ok = false, err = a.name .. "/" .. act.id .. " does not apply to " .. tostring(try(function() return item:getFullType() end)) }
    end
    local log = {}
    local ctx = { player = playerFor(player), log = function(m) log[#log + 1] = tostring(m) end, addon = a }
    local p = normParams(act, params)
    local ok, res, cmds = WB.serverContext(function() return act.run(item, p, ctx) end)
    return { ok = ok, result = ok and res or nil, err = (not ok) and tostring(res) or nil, log = log, commands = cmds,
             addon = a.id, action = act.id, params = p }
end

-- Craft-input prep: steps = { {addon=, action=, params=} | {"addon/action", params} }.
-- Returns a list of error strings (empty on success).
function WB.addonPrep(item, steps, player)
    local errs = {}
    for _, st in ipairs(steps or {}) do
        local addonId, actionId, params = st.addon, st.action, st.params
        if not addonId and type(st[1]) == "string" then
            addonId, actionId = st[1]:match("^([^/]+)/(.+)$")
            params = st[2]
        end
        local ok, r = pcall(WB.runAddonAction, item, addonId, actionId, params, player)
        if not ok then errs[#errs + 1] = tostring(r)
        elseif not r.ok then errs[#errs + 1] = tostring(addonId) .. "/" .. tostring(actionId) .. ": " .. tostring(r.err) end
    end
    return errs
end

-- One-line summaries for compact views (board cards): an addon may define
-- badge = function(item) return text, tone end   (tone: "accent"|"pass"|"fail"|nil).
-- Not filtered by appliesTo: a badge decides for itself (a dismantled head is
-- not a weapon but still carries a soul). Return nil for "nothing to say".
function WB.addonBadges(item)
    local out = {}
    for _, id in ipairs(WB.addonOrder) do
        local a = WB.addons[id]
        if not a.disabled and type(a.badge) == "function" then
            local ok, text, tone = pcall(a.badge, item)
            if ok and text then out[#out + 1] = { addon = a.id, text = tostring(text), tone = tone } end
        end
    end
    return out
end

-- Every applicable panel for an item: { {addon, id, title, data | error} }.
function WB.addonPanelsFor(item)
    local out = {}
    for _, id in ipairs(WB.addonOrder) do
        local a = WB.addons[id]
        if not a.disabled then
            for _, pn in ipairs(a.panels) do
                if check(pn.appliesTo or a.appliesTo, item) then
                    local ok, data = pcall(pn.render, item)
                    out[#out + 1] = { addon = a.id, addonName = a.name, id = pn.id, title = pn.title or pn.id,
                                      data = ok and data or nil, error = (not ok) and tostring(data) or nil }
                end
            end
        end
    end
    return out
end

local function describeAddon(a, item)
    local actions = {}
    for _, act in ipairs(a.actions) do
        actions[#actions + 1] = {
            id = act.id, label = act.label or act.id, doc = act.doc, params = act.params or {},
            applies = item and check(act.appliesTo or a.appliesTo, item) or nil,
        }
    end
    local panels = {}
    for _, pn in ipairs(a.panels) do panels[#panels + 1] = { id = pn.id, title = pn.title or pn.id } end
    local presets = {}
    for _, pr in ipairs(a.presets) do
        local steps = {}
        for _, st in ipairs(pr.steps or {}) do
            steps[#steps + 1] = { addon = a.id, action = st[1] or st.action, params = st[2] or st.params or {} }
        end
        presets[#presets + 1] = { label = pr.label, doc = pr.doc, steps = steps,
                                  applies = item and check(pr.appliesTo or a.appliesTo, item) or nil }
    end
    return { id = a.id, name = a.name, description = a.description, file = a.file, disabled = a.disabled,
             applies = item and check(a.appliesTo, item) or nil, actions = actions, panels = panels, presets = presets }
end

-- args.type: also say which actions apply to that item type (instances a throwaway item).
WB.register("addons", function(a)
    local item
    if a and a.type and a.type ~= "" and PZEngine and PZEngine.available() then
        item = try(function() return PZEngine.instanceItem(a.type) end)
    end
    local list = {}
    for _, id in ipairs(WB.addonOrder) do list[#list + 1] = describeAddon(WB.addons[id], item) end
    return { addons = list, loadErrors = WB.addonLoadErrors }
end)

local function itemFor(a)
    if a.ref then
        local it = WB.deref(a.ref)
        if not it then error("ref $" .. tostring(a.ref) .. " is gone (VM restarted?)") end
        return it
    end
    if a.type then
        local it = PZEngine.instanceItem(a.type)
        if not it then error("unknown item " .. tostring(a.type)) end
        return it
    end
    error("addonRun needs ref or type")
end

local function snapshot(it)
    local info = WB.craft and WB.craft.itemInfo and WB.craft.itemInfo(it) or { ref = WB.ref(it) }
    info.panels = WB.addonPanelsFor(it)
    info.badges = WB.addonBadges(it)
    return info
end

WB.register("addonRun", function(a)
    local it = itemFor(a)
    local before = WB.addonPanelsFor(it)
    local r = WB.runAddonAction(it, a.addon, a.action, a.params)
    r.before = before
    r.item = snapshot(it)
    return r
end)

WB.register("addonPanels", function(a)
    return snapshot(itemFor(a))
end)

-- ── board actions (timed actions / client commands, see 35_actions.lua) ────
-- Declared on an addon:
--   boardActions = { { id, label, doc, kind = "timed" | "command",
--       slots = { { name = "gun", label = "gun", accepts = function(item) ... end }, ... },
--       params = { ... same as actions ... },
--       run = function(items, p, ctx) ... end } }
-- items[name] = the live item in that slot. ctx: player, mode ("sp" | "mp"),
-- log(msg), runTimed(action, opts), clientCommand(module, command, args),
-- serverRequire(name). Slot items are put in the player's inventory first.

local function boardActionDef(addonId, actionId)
    local a = WB.addons[addonId]
    if not a then error("no addon " .. tostring(addonId)) end
    if a.disabled then error(a.name .. " is disabled: " .. a.disabled) end
    for _, b in ipairs(a.boardActions or {}) do if b.id == actionId then return a, b end end
    error(a.name .. " has no board action " .. tostring(actionId))
end

WB.register("boardActions", function()
    local out = {}
    for _, id in ipairs(WB.addonOrder) do
        local a = WB.addons[id]
        if not a.disabled then
            for _, b in ipairs(a.boardActions or {}) do
                local slots = {}
                for _, s in ipairs(b.slots or {}) do slots[#slots + 1] = { name = s.name, label = s.label or s.name, hint = s.hint } end
                out[#out + 1] = { addon = a.id, addonName = a.name, id = b.id, label = b.label or b.id, doc = b.doc,
                                  kind = b.kind or "timed", slots = slots, params = b.params or {} }
            end
        end
    end
    return { actions = out }
end)

-- Which slot an item fits: the first empty slot whose accepts() passes.
WB.register("boardActionSlot", function(a)
    local _, b = boardActionDef(a.addon, a.action)
    local it = WB.deref(a.ref)
    if not it then return { slot = nil } end
    local taken = {}
    for _, n in ipairs(a.taken or {}) do taken[n] = true end
    for _, s in ipairs(b.slots or {}) do
        if not taken[s.name] then
            local ok, r = pcall(s.accepts or function() return true end, it)
            if ok and r then return { slot = s.name } end
        end
    end
    return { slot = nil }
end)

WB.register("boardActionRun", function(a)
    local addon, b = boardActionDef(a.addon, a.action)
    local p = playerFor(nil)
    if not p then error("no player (engine unavailable?)") end
    local inv = p:getInventory()
    pcall(function() p:setPrimaryHandItem(nil); p:setSecondaryHandItem(nil) end)
    inv:removeAllItems()
    local items, before, missing = {}, {}, {}
    for _, s in ipairs(b.slots or {}) do
        local ref = a.slots and a.slots[s.name]
        local it = ref and WB.deref(ref)
        if it then items[s.name] = it; inv:AddItem(it); before[s.name] = WB.addonPanelsFor(it)
        elseif not s.optional then missing[#missing + 1] = s.name end
    end
    if #missing > 0 then return { ok = false, err = "empty slot(s): " .. table.concat(missing, ", ") } end
    local present = {}
    for _, it in ipairs(WB.list(inv:getItems())) do present[it] = true end

    local log = {}
    local ctx = {
        player = p, mode = a.mode or "sp", addon = addon,
        log = function(m) log[#log + 1] = tostring(m) end,
        runTimed = function(action, opts) opts = opts or {}; opts.mode = opts.mode or a.mode or "sp"; return WB.runTimed(action, opts) end,
        clientCommand = function(m, c, args) return WB.clientCommand(p, m, c, args) end,
        serverRequire = WB.serverRequire,
    }
    local params = normParams(b, a.params)
    -- Record sends without forcing a context: runTimed pins its own per side.
    local cmds = {}
    local saved = { sendServerCommand, sendClientCommand, sendAddItemToContainer, sendRemoveItemFromContainer }
    sendServerCommand = function(x, y, z, w)
        if type(x) == "string" then cmds[#cmds + 1] = { module = x, command = y, args = z }
        else cmds[#cmds + 1] = { module = y, command = z, args = w } end
    end
    sendClientCommand = function(_, m, c, args) cmds[#cmds + 1] = { module = m, command = c, args = args, toServer = true } end
    sendAddItemToContainer = function() end
    sendRemoveItemFromContainer = function() end
    local ok, res, trace = pcall(b.run, items, params, ctx)
    sendServerCommand, sendClientCommand, sendAddItemToContainer, sendRemoveItemFromContainer = saved[1], saved[2], saved[3], saved[4]

    local slotsOut = {}
    for name, it in pairs(items) do
        local still = inv:contains(it) or p:getPrimaryHandItem() == it
        local info = snapshot(it)
        info.panelsBefore = before[name]
        info.gone = not still or nil
        -- Did the action change this item at all (as its panels see it)?
        -- A server handler that refuses usually just returns: no change.
        info.changed = (not still) or WB.json(info.panels) ~= WB.json(before[name])
        slotsOut[name] = info
    end
    local created = {}
    for _, it in ipairs(WB.list(inv:getItems())) do
        if not present[it] then created[#created + 1] = snapshot(it) end
    end
    return {
        ok = ok and not (type(res) == "table" and res.ok == false), result = ok and res or nil,
        err = (not ok) and (tostring(res) .. (trace and ("\n" .. tostring(trace)) or "")) or nil,
        slots = slotsOut, created = created, commands = cmds, log = log, mode = ctx.mode,
    }
end)
