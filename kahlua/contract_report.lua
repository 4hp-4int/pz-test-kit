--[[
    PZ Test Kit — contract pass, the report
    ========================================
    Reads _pz_contract_results = { sp = ..., client = ..., dedi = ... } (one
    contract.lua result per boot profile) and returns
        { checks = { { name, status = "pass"|"fail"|"skip", text }, ... },
          notes  = "..." }
    which the runner prints and counts like tests.

    CHECK 1 — timed-action signatures survive the wire.
      NetTimedAction.set (NetTimedAction.java:42-51) sends an action by the
      declared parameter names of its class's new(); the server rebuilds it
      with <Type>.new(those values, in that order) (:148-163). So on any
      machine, a replicating vanilla action whose new() parameters differ from
      vanilla's after the mod loads sends the wrong thing -- typically a
      `function(self, a, b, ...)` wrapper, which sends a and b only. And a
      mod's own replicating action whose new() takes `...` never sends those
      arguments at all.

    CHECK 2 — a dedicated server installs the server-side hooks SP does.
      Every own function field of a vanilla timed action that the mod
      replaced in SP but NOT on a dedi, for a method the server runs
      (new isValid isValidStart serverStart complete serverStop getDuration
      animEvent), on an action that replicates. The usual cause is
      installing from OnGameStart/OnLoad/OnPreMapLoad, none of which a dedi
      fires. Hooks on client-only methods (perform, start, update, stop, ...)
      are listed as a note, not a failure. Vanilla GLOBAL functions follow
      the same rule (a global the dedi's vanilla also defines, wrapped in SP,
      never on a dedi): SaucedCarts' forceDropHeavyItems guard slipped
      through when only classes were checked.

    Silence a deliberate case with, in pz-test.lua:
        contract_allow = { "ISFooAction.complete", "ISBarAction.new" }
]]

local R = _pz_contract_results
local cfg = _pz_config or {}
local allow = {}
for _, k in ipairs(cfg.contract_allow or {}) do allow[k] = true end

local checks, notes = {}, {}
local function add(name, status, text) checks[#checks + 1] = { name = name, status = status, text = text or "" } end

local PROFILES = { "client", "dedi", "sp" }
for _, p in ipairs(PROFILES) do
    if R[p] and R[p].skipped then
        add("timed-action signatures survive the wire", "skip", R[p].skipped)
        add("dedicated server installs the server-side hooks", "skip", R[p].skipped)
        return { checks = checks, notes = "" }
    end
end

local function split(s)
    local t = {}
    for w in tostring(s or ""):gmatch("[^,]+") do t[#t + 1] = w end
    return t
end
local function sortedKeys(t)
    local ks = {}
    for k in pairs(t) do ks[#ks + 1] = k end
    table.sort(ks)
    return ks
end

-- ── Check 1 ────────────────────────────────────────────────────────────────

local sigIssues = {}   -- [Type] = { text, profiles = {} }
local checkedVanilla, checkedMod = {}, {}
for _, p in ipairs(PROFILES) do
    for name, sig in pairs(R[p].sigs or {}) do
        local text
        if sig.vanilla then
            checkedVanilla[name] = true
            if sig.replicates and (sig.params ~= sig.vanillaParams or (sig.vararg and not sig.vanillaVararg)) then
                local now, was = split(sig.params), split(sig.vanillaParams)
                local lost = {}
                for i, n in ipairs(was) do
                    if now[i] ~= n then lost[#lost + 1] = n end
                end
                text = string.format("%s.new: vanilla sends (%s); with the mod loaded it sends (%s)%s",
                    name, sig.vanillaParams or "", sig.params,
                    #lost > 0 and (" -- " .. table.concat(lost, ", ")
                        .. " arrive nil or misplaced on the server") or "")
            end
        else
            checkedMod[name] = true
            if sig.replicates and sig.vararg then
                text = string.format("%s.new declares `...` after (%s): replicating actions are sent by "
                    .. "parameter name, so those arguments never reach the server", name, sig.params)
            end
        end
        if text and not allow[name .. ".new"] then
            sigIssues[name] = sigIssues[name] or { text = text, profiles = {} }
            table.insert(sigIssues[name].profiles, p)
        end
    end
end
local nV, nM = #sortedKeys(checkedVanilla), #sortedKeys(checkedMod)
if #sortedKeys(sigIssues) > 0 then  -- Kahlua has no next()
    local lines = {}
    for _, name in ipairs(sortedKeys(sigIssues)) do
        local i = sigIssues[name]
        lines[#lines + 1] = i.text .. " [" .. table.concat(i.profiles, ", ") .. "]"
    end
    lines[#lines + 1] = "(NetTimedAction.java:42-51 sends action[name] for each declared parameter of new(); "
        .. "restate the full signature in the wrapper)"
    add("timed-action signatures survive the wire", "fail", table.concat(lines, "\n"))
else
    add("timed-action signatures survive the wire", "pass",
        string.format("%d vanilla + %d mod actions", nV, nM))
end

-- ── Check 2 ────────────────────────────────────────────────────────────────

local SERVER_RUN = {
    new = true, isValid = true, isValidStart = true, serverStart = true,
    complete = true, serverStop = true, getDuration = true, animEvent = true,
}
local spHooks, dediHooks = R.sp.hooks or {}, R.dedi.hooks or {}
local missing, clientOnly = {}, {}
for _, key in ipairs(sortedKeys(spHooks)) do
    if not dediHooks[key] and not allow[key] then
        local class, method = key:match("^(.-)%.(.+)$")
        local sig = R.sp.sigs[class]
        if not R.dedi.sigs[class] then
            -- A client-folder class: the server has no copy to hook.
        elseif method == "<class replaced>" or (SERVER_RUN[method] and sig and sig.replicates) then
            missing[#missing + 1] = string.format("%s: installed in SP by %s, never on a dedicated server",
                key, spHooks[key])
        else
            clientOnly[#clientOnly + 1] = key
        end
    end
end
-- Vanilla global functions get the same rule: wrapped in SP, present on a
-- dedi (its vanilla defines it too), never wrapped there. Which machine calls
-- a global can't be read off it, so every dedi-side vanilla global counts;
-- list deliberate client-only wrappers in contract_allow by name.
local spGlobals, dediGlobals = R.sp.globalHooks or {}, R.dedi.globalHooks or {}
for _, name in ipairs(sortedKeys(spGlobals)) do
    if not dediGlobals[name] and not allow[name] and (R.dedi.globals or {})[name] then
        missing[#missing + 1] = string.format("%s (global function): installed in SP by %s, never on a dedicated server",
            name, spGlobals[name])
    end
end
local nHooks = #sortedKeys(spHooks) + #sortedKeys(spGlobals)
if #missing > 0 then
    missing[#missing + 1] = "(a dedi fires OnGameBoot, OnInitWorld, OnInitGlobalModData, OnServerStarted -- "
        .. "never OnGameStart/OnLoad/OnPreMapLoad/OnConnected; install from one it fires, or list the hook in "
        .. "contract_allow if it is deliberately client-only)"
    add("dedicated server installs the server-side hooks", "fail", table.concat(missing, "\n"))
else
    add("dedicated server installs the server-side hooks", "pass",
        string.format("%d vanilla hooks in SP", nHooks))
end
if #clientOnly > 0 then
    notes[#notes + 1] = "SP-only hooks on client-run methods (not a failure): " .. table.concat(clientOnly, ", ")
end

-- ── Notes: what the headless load could not do ─────────────────────────────

for _, p in ipairs({ "sp", "client", "dedi" }) do
    local r = R[p]
    local bits = {}
    local modErrors = #r.loadErrors - r.vanillaErrors
    if modErrors > 0 then bits[#bits + 1] = modErrors .. " mod file(s) failed to load headless" end
    if #r.eventErrors > 0 then bits[#bits + 1] = #r.eventErrors .. " boot listener(s) errored" end
    if r.vanillaErrors > 0 then
        bits[#bits + 1] = r.vanillaErrors .. "/" .. r.vanillaFiles .. " vanilla action file(s) failed to load"
    end
    if #bits > 0 then
        notes[#notes + 1] = p .. ": " .. table.concat(bits, "; ")
        for _, e in ipairs(r.loadErrors) do print("[contract " .. p .. "] load: " .. e) end
        for _, e in ipairs(r.eventErrors) do print("[contract " .. p .. "] event: " .. e) end
    end
end

-- Full hook inventory per profile; the runner shows it only when a check fails.
for _, p in ipairs({ "sp", "client", "dedi" }) do
    for _, key in ipairs(sortedKeys(R[p].hooks or {})) do
        print("[contract " .. p .. "] hook: " .. key .. " <- " .. R[p].hooks[key])
    end
end

return { checks = checks, notes = table.concat(notes, "\n") }
