-- ============================================================================
-- PZShell — in-process Lua REPL for dedicated servers
-- ============================================================================
-- Polls ${Zomboid}/Lua/pz-shell/queue.txt for code, executes it via
-- loadstring()+pcall(), writes output to ${Zomboid}/Lua/pz-shell/result.txt.
--
-- CONTEXT: server + singleplayer (NOT MP client). Mod is dev-only — arbitrary
-- code execution, do not ship on public Workshop.
--
-- SAFETY GATE: polling does nothing unless ${Zomboid}/Lua/pz-shell/enabled
-- exists. Deploy the mod to your dev dedi, touch the flag, go; remove the
-- flag to disable without restarting.
--
-- PROTOCOL:
--   1. host writes code to queue.lua
--   2. server sees non-empty queue.lua → reads, executes, writes result.lua
--   3. server truncates queue.lua (signals "consumed")
--   4. host reads result.lua, truncates it
--   5. next request
--
-- Queue/result are the same file for every request — no directory listing
-- needed (PZ's Lua API doesn't expose one). Host-side file writes are atomic
-- enough for this loop because the host waits for queue to be empty before
-- writing the next request.
-- ============================================================================

-- MP clients are opt-in. The original blanket `if isClient() then return end`
-- made client-side state completely un-introspectable, which matters more than
-- the ambiguity it was avoiding: a whole class of bug (tooltips, display names,
-- anything rendered) lives ONLY on the client, and debugging it without a probe
-- means guessing. Three wrong guesses in one session is what prompted this.
--
-- The client reads its OWN Zomboid/Lua/pz-shell/, which is a different
-- directory from the server's, so the two never collide — on a local dedi the
-- server's lives inside the container. Gate is per-directory too, so enabling
-- the shell for the server does not enable it for the client.
--
-- Opt in by creating the marker next to the gate:
--   Zomboid/Lua/pz-shell/client-enabled
if isClient() then
    local r = getFileReader("pz-shell/client-enabled", false)
    if not r then return end
    r:close()
end

local QUEUE_PATH   = "pz-shell/queue.txt"
local RESULT_PATH  = "pz-shell/result.txt"
local ENABLED_PATH = "pz-shell/enabled"

-- Existence check: getFileReader(path, false) resolves `path` against the
-- Lua cache dir (Zomboid/Lua/) and returns nil if the file is missing.
-- Don't use fileExists() — despite its doc, it resolves relative to the
-- process CWD (/home/steam/pzserver/ on dedi), not the Zomboid dir.
local function zomboidLuaExists(relPath)
    local r = getFileReader(relPath, false)
    if r then r:close(); return true end
    return false
end

-- ─── File I/O ────────────────────────────────────────────────────────────────

local function readFile(path)
    local reader = getFileReader(path, false)
    if not reader then return nil end
    local lines = {}
    while true do
        local line = reader:readLine()
        if not line then break end
        table.insert(lines, line)
    end
    reader:close()
    return table.concat(lines, "\n")
end

local function writeFile(path, content)
    local writer = getFileWriter(path, true, false) -- createIfNull=true, append=false (truncate)
    if not writer then return false end
    writer:write(content or "")
    writer:close()
    return true
end

-- ─── Request dispatch ────────────────────────────────────────────────────────

--- Run a snippet of Lua and return a string with captured print() output and
--- the returned value (or error). Never throws.
local function evalSnippet(code)
    local output = {}
    local function emit(s) table.insert(output, s) end

    -- Wrap print() so the snippet's output is both returned in the eval
    -- result AND flushed through to the real dedi log. The latter lets
    -- `pz-shell tail` see the lines in real time. Dedi Lua is single-
    -- threaded, so other handlers running mid-pcall will briefly land in
    -- our emit buffer too — acceptable and usually invisible.
    local origPrint = print
    _G.print = function(...)
        local n = select("#", ...)
        local parts = {}
        for i = 1, n do parts[i] = tostring(select(i, ...)) end
        local line = table.concat(parts, "\t")
        emit(line)
        origPrint(line)
    end

    local fn, compileErr = loadstring(code, "=pz-shell")

    local resultLine
    if not fn then
        resultLine = "COMPILE ERROR: " .. tostring(compileErr)
    else
        local ok, result = pcall(fn)
        _G.print = origPrint
        if not ok then
            resultLine = "ERROR: " .. tostring(result)
        elseif result ~= nil then
            resultLine = "=> " .. tostring(result)
        end
    end
    _G.print = origPrint -- also restore on compile-error path

    if resultLine then emit(resultLine) end
    return table.concat(output, "\n")
end

--- One poll cycle: look for a non-empty queue, execute it, write result,
--- clear the queue.
local function pollOnce()
    if not zomboidLuaExists(ENABLED_PATH) then return end
    if not zomboidLuaExists(QUEUE_PATH) then return end

    local code = readFile(QUEUE_PATH)
    if not code or code == "" then return end

    -- Clear queue first so the same request isn't re-executed if the eval
    -- itself throws or hangs the tick loop.
    writeFile(QUEUE_PATH, "")

    local output = evalSnippet(code)
    writeFile(RESULT_PATH, output)
end

-- ─── Public API: PZShell.serialize / PZShell.defaultSnapshot ────────────────
-- Exposed to eval so `pz-shell snapshot` can call them without embedding
-- a huge Lua literal in the bash CLI. Attached to _G.PZShell for discoverability.

_G.PZShell = _G.PZShell or {}

--- Recursively serialise a pure-Lua value to a loadstring-ready Lua expression.
--- Handles number/boolean/string/nil/table. Skips functions/userdata with a
--- `nil --[[<type>]]` comment marker. Detects cycles via a seen-set (fails loud).
--- @param v any
--- @param indent string|nil current indent (internal)
--- @param seen table|nil cycle-detector (internal)
--- @return string
function PZShell.serialize(v, indent, seen)
    indent = indent or ""
    seen = seen or {}
    local t = type(v)
    if t == "number" or t == "boolean" then return tostring(v) end
    if t == "nil" then return "nil" end
    if t == "string" then return string.format("%q", v) end
    if t == "table" then
        if seen[v] then return "nil --[[cycle]]" end
        seen[v] = true
        local parts = { "{\n" }
        local nextIndent = indent .. "  "
        for k, val in pairs(v) do
            local keyStr
            if type(k) == "string" and k:match("^[%a_][%a%d_]*$") then
                keyStr = k
            else
                keyStr = "[" .. PZShell.serialize(k, "", seen) .. "]"
            end
            parts[#parts + 1] = nextIndent .. keyStr .. " = "
                .. PZShell.serialize(val, nextIndent, seen) .. ",\n"
        end
        parts[#parts + 1] = indent .. "}"
        seen[v] = nil
        return table.concat(parts)
    end
    return "nil --[[" .. t .. "]]"
end

--- Capture a VPS-focused default snapshot. A single table with:
---   vps_runtime   = VorpallySauced.WeaponData._runtime  (all in-memory accumulators)
---   vps_bonds     = bond registry snapshot if DiscoveryLog exposes one
---   sandbox       = VPS sandbox vars (immutable tuning values)
---   connected     = connected player usernames + their hand weapons' VPS ModData
---   captured_at   = os.time() snapshot epoch
--- Pure-Lua data only — Java objects are flattened to identifiers/getters.
function PZShell.defaultSnapshot()
    local snap = {
        captured_at = (os.time and os.time()) or 0,
        vps_runtime = nil,
        sandbox = nil,
        connected = {},
    }

    -- VPS runtime accumulators (appliedClipBonus etc.)
    local VPS = _G.VorpallySauced
    if VPS and VPS.WeaponData and VPS.WeaponData._runtime then
        local copy = {}
        for wid, rt in pairs(VPS.WeaponData._runtime) do
            -- Shallow copy so we don't pin a ref to the live table.
            local entry = {}
            for k, v in pairs(rt) do
                if type(v) ~= "function" and type(v) ~= "userdata" then
                    entry[k] = v
                end
            end
            copy[tostring(wid)] = entry
        end
        snap.vps_runtime = copy
    end

    -- Sandbox snapshot (tuning values at capture time)
    if SandboxVars and SandboxVars.VorpallySauced then
        local sv = {}
        for k, v in pairs(SandboxVars.VorpallySauced) do
            local tv = type(v)
            if tv == "number" or tv == "boolean" or tv == "string" then sv[k] = v end
        end
        snap.sandbox = sv
    end

    -- Connected players + their primary hand weapon's ModData.
    local online = getOnlinePlayers and getOnlinePlayers() or nil
    if online and online.size then
        for i = 0, online:size() - 1 do
            local p = online:get(i)
            if p then
                local entry = { username = p:getUsername() }
                -- Prefer primary hand; fall back to first weapon in inventory
                -- (server's getPrimaryHandItem is overwritten by the next
                -- client tick, so setPrimaryHandItem from a puppet call
                -- flips back to nil between evals).
                local w = p.getPrimaryHandItem and p:getPrimaryHandItem()
                if not w then
                    local items = p:getInventory():getItems()
                    for j = 0, items:size() - 1 do
                        local it = items:get(j)
                        if it and it.IsWeapon and it:IsWeapon() then w = it; break end
                    end
                end
                if w then
                    entry.weapon = {
                        id       = w:getID(),
                        fullType = w.getFullType and w:getFullType() or nil,
                        maxAmmo  = w.getMaxAmmo and w:getMaxAmmo() or nil,
                        clipSize = w.getClipSize and w:getClipSize() or nil,
                    }
                    local md = w:getModData()
                    local vps = md and md.VorpallySauced
                    -- expand via getModData (triggers unpack of packed format)
                    if VPS and VPS.WeaponData and VPS.WeaponData.getModData then
                        vps = VPS.WeaponData.getModData(w) or vps
                    end
                    if vps then
                        -- Shallow copy to drop any userdata refs.
                        local copy = {}
                        for k, v in pairs(vps) do
                            local tv = type(v)
                            if tv == "number" or tv == "boolean" or tv == "string" then
                                copy[k] = v
                            end
                        end
                        entry.weapon.vps = copy
                    end
                end
                snap.connected[#snap.connected + 1] = entry
            end
        end
    end

    return snap
end

-- ─── Structured log sink: PZShell.tap ───────────────────────────────────────
-- Per-mod log file. Any mod (VPS, SaucedCarts, ThirdPartyX) that wants a
-- filtered stream can do:
--
--   local log = PZShell.tap("VorpallySauced")
--   log.info("player equipped shotgun id=" .. id)
--   log.error("unexpected nil weapon")
--
-- Entries land at Zomboid/Lua/pz-shell/stream/<modName>.log, timestamped,
-- append-mode. `pz-shell tail-mod <name>` host-side tails the file so you
-- get clean per-mod streams instead of grepping the 95%-noise debug log.
-- No-op safe on PZShell-less dedis (PZShell.tap is just a function).

PZShell._STREAM_DIR = "pz-shell/stream"

local function _streamPath(modName)
    -- Restrict to alphanumeric + underscore + hyphen so the filename stays
    -- predictable even if a mod uses weird chars in its name.
    local safe = tostring(modName or "unknown"):gsub("[^%a%d_%-]", "_")
    return PZShell._STREAM_DIR .. "/" .. safe .. ".log"
end

local function _nowStamp()
    if os.date then return os.date("[%Y-%m-%d %H:%M:%S]") end
    return "[" .. tostring((os.time and os.time()) or 0) .. "]"
end

local function _streamAppend(path, line)
    local writer = getFileWriter(path, true, true) -- createIfNull=true, append=true
    if not writer then return false end
    writer:write(line .. "\n")
    writer:close()
    return true
end

--- Create a logger for a specific mod. Returns a table with log/debug/info/
--- warn/error methods; each writes a timestamped line to the mod's stream
--- file under Zomboid/Lua/pz-shell/stream/<modName>.log.
function PZShell.tap(modName)
    local path = _streamPath(modName)
    local function sev(level)
        return function(...)
            local n = select("#", ...)
            local parts = {}
            for i = 1, n do parts[i] = tostring(select(i, ...)) end
            _streamAppend(path, _nowStamp() .. " [" .. level .. "] " .. table.concat(parts, " "))
        end
    end
    return {
        log   = sev("LOG"),
        info  = sev("INFO"),
        debug = sev("DEBUG"),
        warn  = sev("WARN"),
        error = sev("ERROR"),
        _path = path,  -- exposed for introspection
    }
end

--- Paths for the snapshot store. Held relative to Zomboid/Lua/ (getFileReader
--- root). `getFileWriter` auto-creates missing parents.
PZShell._SNAPSHOT_DIR = "pz-shell/snapshots"

--- Write a snapshot file. Returns bytes written (string length).
function PZShell.saveSnapshot(name, value)
    local src = "-- pz-shell snapshot\nreturn " .. PZShell.serialize(value) .. "\n"
    local path = PZShell._SNAPSHOT_DIR .. "/" .. name .. ".txt"
    local ok = writeFile(path, src)
    return ok and #src or 0
end

--- Read and deserialise a snapshot. Returns (value, err).
function PZShell.loadSnapshot(name)
    local path = PZShell._SNAPSHOT_DIR .. "/" .. name .. ".txt"
    local src = readFile(path)
    if not src then return nil, "snapshot not found: " .. name end
    local fn, compileErr = loadstring(src, "=snapshot/" .. name)
    if not fn then return nil, "load error: " .. tostring(compileErr) end
    local ok, val = pcall(fn)
    if not ok then return nil, "run error: " .. tostring(val) end
    return val, nil
end

-- ─── Scheduling ──────────────────────────────────────────────────────────────
-- Two fallback polling sources because PZ's documentation of which Events
-- fire on dedi is unreliable:
--   - OnTick: fires per server tick (~20Hz on dedi). Preferred — gives
--     sub-second latency. Throttled to ~4Hz to avoid log spam / extra I/O.
--   - EveryOneMinute: fires server-side for sure. Safety net.

-- Event dispatch map on dedi (empirical, verified 2026-04-20):
--   OnTick         ~12 Hz  — server logic loop. Primary fast poll.
--   EveryOneMinute ~1 per game-minute (~1.3 real seconds at default DayLength)
--   OnPlayerUpdate  fires per connected player per tick. Bonus coverage when
--                   players are online.
--   EveryTenMinutes / EveryHours / EveryDays  also fire; overkill for polling
--                   but handy as a "nothing else worked" fallback.
--
-- Decomp note (IngameState.java): OnTick is technically only dispatched from
-- client-side IngameState, but something in GameServer's serverLogicThread
-- also fires it on dedi. Empirically works; don't rely on it exclusively.

local tickCount = 0
local TICKS_PER_POLL = 3  -- ~4 Hz poll at 12tps

local function safePoll(tag)
    local ok, err = pcall(pollOnce)
    if not ok then
        pcall(writeFile, RESULT_PATH, "POLL ERROR (" .. tag .. "): " .. tostring(err))
    end
end

Events.OnTick.Add(function()
    tickCount = tickCount + 1
    if tickCount % TICKS_PER_POLL == 0 then safePoll("tick") end
end)
Events.EveryOneMinute.Add(function() safePoll("min") end)
Events.OnPlayerUpdate.Add(function() safePoll("pu") end)

Events.OnServerStarted.Add(function()
    print("[PZShell] ready. Enable with: touch Zomboid/Lua/" .. ENABLED_PATH)
    print("[PZShell] queue path: Zomboid/Lua/" .. QUEUE_PATH)
    print("[PZShell] result path: Zomboid/Lua/" .. RESULT_PATH)
end)

-- Also log on SP load (isServer() false + isClient() false), useful for
-- local testing outside the docker dedi.
Events.OnGameStart.Add(function()
    if isServer() or isClient() then return end
    print("[PZShell] ready in SP. Enable with: touch Zomboid/Lua/" .. ENABLED_PATH)
end)

-- 42.20 idle-dedi kick support: on an empty 42.20 dedicated server neither
-- OnTick nor EveryOneMinute fires reliably (observed 2026-08: OnTick never,
-- EveryOneMinute per-frame burst after boot then silent), so the event polls
-- can starve. Running one poll at load makes `pz-console "reloadlua
-- PZShell.lua"` a deterministic kick: write queue -> reloadlua -> result.
pcall(pollOnce)
