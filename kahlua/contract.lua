--[[
    PZ Test Kit — contract pass, one boot profile
    ==============================================
    The runner (runContract) builds a fresh env per profile, sets
    _pz_contract_profile to "sp" | "client" | "dedi", and runs this file.
    contract_report.lua compares the three results afterwards.

    WHY. Two shipped MP bugs, neither catchable by a test nobody wrote:

      SaucedCarts 2.1.21 wrapped ISUnequipAction.new as
        function(self, character, item, ...)
      NetTimedAction sends an action by the declared parameter NAMES of its
      class's new() (NetTimedAction.java:42-51), so only character and item
      reached the server: nobody on any server could unequip or drop.

      SaucedCarts 2.1.3-2.1.22 installed its ISUnequipAction/
      ISDropWorldItemAction complete() hooks from OnGameStart, which a
      dedicated server never fires. Tests installed the hooks by hand.

    So instead of trusting tests to imagine MP, this loads the whole mod the
    way each kind of machine does and records what it ends up with.

    PER PROFILE
      1. Context: sp = neither, client = isClient, dedi = isServer.
      2. Vanilla: every TimedActions file from the PZ install, in the folders
         that machine loads (sp: shared+client+server, client: shared+client,
         dedi: shared+server). Registered as requirable modules, so load
         order follows require like the game. Classes the env already has
         (vanilla_requires) are kept, not reloaded.
      3. Snapshot every timed-action class: new()'s declared parameters and
         its own function fields.
      4. Every mod file (Tests/ excluded) in the same folders, shared first,
         then client, then server, alphabetical within -- PZ's order.
      5. The boot events that machine really fires, in order (decompiled
         42.21): OnGameBoot (GameServer.java:1499 / GameWindow.java:673);
         the distribution merges + OnInitWorld (IsoWorld.java:1907-1914) and
         OnInitGlobalModData (GlobalModData.java:55) on every machine;
         OnPreMapLoad (GameLoadingState.java:234), OnGameStart + OnLoad
         (IngameState.java:769-770) only where a game state runs (SP,
         client); OnConnected (ConnectToServerState.java:166) on a client;
         OnServerStarted (GameServer.java:1536) only on a dedi.
      6. Record each class's signature and every own field the mod replaced,
         with the step that installed it (file load or the event).

    Returns a plain table; see the `result` fields below.
]]

local profile = _pz_contract_profile
local result = {
    profile     = profile,
    sigs        = {},   -- [Type] = { params, vararg, vanillaParams, vanilla, replicates }
    hooks       = {},   -- ["Type.field"] = origin ("file load" | event name)
    loadErrors  = {},   -- array of "name: message"
    eventErrors = {},   -- array of "Event: message"
    vanillaFiles = 0,
    vanillaErrors = 0,
    modFiles    = 0,
}

local cfg = _pz_config or {}
if cfg.contract == false then
    result.skipped = "contract = false in pz-test.lua"
    return result
end
if not _pz_vanilla_list or not _pz_vanilla_list("shared") then
    result.skipped = "no PZ install found (set PZ_INSTALL_DIR)"
    return result
end

local CONTEXT = {
    sp     = { client = false, server = false, folders = { "shared", "client", "server" } },
    client = { client = true,  server = false, folders = { "shared", "client" } },
    dedi   = { client = false, server = true,  folders = { "shared", "server" } },
}
local EVENTS = {
    sp     = { "OnGameBoot", "OnPreMapLoad", "OnPreDistributionMerge", "OnDistributionMerge",
               "OnPostDistributionMerge", "OnInitWorld", "OnInitGlobalModData", "OnGameStart", "OnLoad" },
    client = { "OnGameBoot", "OnConnected", "OnPreMapLoad", "OnPreDistributionMerge", "OnDistributionMerge",
               "OnPostDistributionMerge", "OnInitWorld", "OnInitGlobalModData", "OnGameStart", "OnLoad" },
    dedi   = { "OnGameBoot", "OnPreDistributionMerge", "OnDistributionMerge",
               "OnPostDistributionMerge", "OnInitWorld", "OnInitGlobalModData", "OnServerStarted" },
}
local ctx = CONTEXT[profile]
assert(ctx, "contract: unknown profile " .. tostring(profile))
isClient = function() return ctx.client end
isServer = function() return ctx.server end

-- ── 2. Vanilla timed actions, requirable ───────────────────────────────────

local function requireName(rel)               -- "shared/TimedActions/X" -> "TimedActions/X"
    return (rel:gsub("^[^/]+/", ""))
end
local function baseName(rel) return rel:match("([^/]+)$") end

local vanillaRels = {}
for _, folder in ipairs(ctx.folders) do
    for _, rel in ipairs(_pz_vanilla_list(folder .. "/TimedActions") or {}) do
        vanillaRels[#vanillaRels + 1] = rel
    end
end
-- The base classes first; everything derives from them.
table.insert(vanillaRels, 1, "shared/TimedActions/ISBaseTimedAction")
table.insert(vanillaRels, 1, "shared/ISBaseObject")

-- Classes vanilla_requires already loaded for real are kept; any other
-- global of the same name is a kit mock (ISBaseTimedAction = {} in
-- mock_environment) and gets replaced, or nothing would derive from the
-- real base and no action would be recognised.
local real = _pz_vanilla_loaded or {}
local toLoad = {}
for _, rel in ipairs(vanillaRels) do
    local name = requireName(rel)
    -- The mod's own module of the same name wins, as in the game.
    if _pz_module_sources[name] == nil and not real[rel] and not toLoad[rel] then
        local src = _pz_vanilla_source(rel)
        if src then
            toLoad[rel] = true
            _G[baseName(rel)] = nil
            _pz_module_sources[name] = src
            _pz_module_files[name] = "vanilla:" .. rel
            -- Real vanilla beats a config stub here: tests stub classes they
            -- don't exercise, but the contract is about the real ones.
            _pz_stub_requires[name] = nil
            _pz_package_loaded[name] = nil
        end
    end
end
for _, rel in ipairs(vanillaRels) do
    local name = requireName(rel)
    if toLoad[rel] then
        toLoad[rel] = nil
        result.vanillaFiles = result.vanillaFiles + 1
        local ok, err = pcall(require, name)
        if not ok then
            result.vanillaErrors = result.vanillaErrors + 1
            result.loadErrors[#result.loadErrors + 1] = "vanilla " .. name .. ": " .. tostring(err)
        end
    end
end

-- ── 3. Snapshot ────────────────────────────────────────────────────────────

local function isTimedAction(name, v)
    if type(v) ~= "table" or rawget(v, "Type") ~= name then return false end
    if type(rawget(v, "new")) ~= "function" then return false end
    local mt, depth = v, 0
    while mt and depth < 32 do
        if mt == ISBaseTimedAction then return true end
        mt = getmetatable(mt)
        depth = depth + 1
    end
    return false
end

local function signature(class)
    local params, vararg = _pz_closure_params(rawget(class, "new"))
    if not params then return nil, false end
    local names = {}
    for i = 2, #params do names[#names + 1] = params[i] end   -- drop self
    return table.concat(names, ","), vararg == true
end

local vanilla = {}   -- [name] = { class, params, vararg, fields = {[k] = fn} }
for name, v in pairs(_G) do
    if type(name) == "string" and isTimedAction(name, v) then
        local params, vararg = signature(v)
        local fields = {}
        for k, f in pairs(v) do
            if type(f) == "function" then fields[k] = f end
        end
        vanilla[name] = { class = v, params = params, vararg = vararg, fields = fields }
    end
end

-- ── 4 + 5. The mod, then the boot events, recording hooks as they appear ───

local function collectHooks(origin)
    for name, snap in pairs(vanilla) do
        local class = _G[name]
        if class ~= snap.class then
            local key = name .. ".<class replaced>"
            if not result.hooks[key] then result.hooks[key] = origin end
        else
            for k, f in pairs(class) do
                if type(f) == "function" and snap.fields[k] ~= f then
                    local key = name .. "." .. tostring(k)
                    if not result.hooks[key] then result.hooks[key] = origin end
                end
            end
        end
    end
end

local folderRank = {}
for i, folder in ipairs(ctx.folders) do folderRank[folder] = i end
local modNames = {}
for name, path in pairs(_pz_module_files) do
    local p = tostring(path):gsub("\\", "/")
    local folder = p:match("/media/lua/([^/]+)/")
    if folder and folderRank[folder] and not p:lower():find("/tests/", 1, true) then
        modNames[#modNames + 1] = { name = name, rank = folderRank[folder], key = p:lower() }
    end
end
table.sort(modNames, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    return a.key < b.key
end)
for _, m in ipairs(modNames) do
    result.modFiles = result.modFiles + 1
    local ok, err = pcall(require, m.name)
    if not ok then result.loadErrors[#result.loadErrors + 1] = m.name .. ": " .. tostring(err) end
end
collectHooks("file load")

for _, evName in ipairs(EVENTS[profile]) do
    local evt = Events[evName]
    local listeners = {}
    for i, fn in ipairs(evt._listeners or {}) do listeners[i] = fn end
    for _, fn in ipairs(listeners) do
        local ok, err
        if evName == "OnInitGlobalModData" then
            ok, err = pcall(fn, true)
        else
            ok, err = pcall(fn)
        end
        if not ok then result.eventErrors[#result.eventErrors + 1] = evName .. ": " .. tostring(err) end
    end
    collectHooks(evName)
end

-- ── 6. Signatures after boot ───────────────────────────────────────────────

for name, v in pairs(_G) do
    if type(name) == "string" and isTimedAction(name, v) then
        local params, vararg = signature(v)
        local snap = vanilla[name]
        result.sigs[name] = {
            params        = params or "",
            vararg        = vararg,
            vanilla       = snap ~= nil,
            vanillaParams = snap and snap.params or nil,
            vanillaVararg = snap and snap.vararg or nil,
            -- LuaTimedActionNew.java:77: only an OWN complete replicates.
            replicates    = rawget(v, "complete") ~= nil,
        }
    end
end

return result
