--[[
    PZ Test Kit — Test Executor
    ===========================
    Called by KahluaTestRunner.java for each test file.
    Receives the test table (returned by the test file), runs each test
    function with player state reset between tests, collects results.

    Returns: total, passed, failed, errors, errorDetails
]]

-- ============================================================================
-- DISCOVER TEST TABLE
-- ============================================================================
-- Two supported patterns:
--
--   Pattern A (return table):
--       local tests = {}
--       tests["foo"] = function() return Assert.isTrue(true) end
--       return tests
--
--   Pattern B (registry call), for mods with their own TestRunner:
--       TestRunner.registerSync("foo", function(self)
--           return Assert.isTrue(true)
--       end)
--
-- For Pattern B we expose `PZTestKit.adoptRegistry(fn)` — your mod can call
-- it after registering to hand the kit a callable list:
--
--       PZTestKit.adoptRegistry(function()
--           local out = {}
--           for name, test in pairs(MyMod.TestRunner.getTests()) do
--               out[name] = function() test:run(); return test:validate() end
--           end
--           return out
--       end)
-- ============================================================================

local testTable = _pz_last_return

if type(testTable) ~= "table" then
    -- Pattern B: check the kit's adoptable registry
    if PZTestKit and PZTestKit._adoptedRegistry then
        local ok, result = pcall(PZTestKit._adoptedRegistry)
        if ok and type(result) == "table" then
            testTable = result
        end
    end
end

-- Pattern C: auto-discover a mod's TestRunner.getTests() registry. Scans _G
-- for any table whose `.TestRunner.getTests` returns a non-empty test table.
-- Handles two shapes:
--   (a) { name = function }         — use directly
--   (b) { name = { run, validate } } — adapt to function form
--       (VPS convention: test:run() mutates state, test:validate() asserts)
-- Tests already run in prior files are DIFFED out via `_pz_runner_seen`.
if type(testTable) ~= "table" then
    _pz_runner_seen = _pz_runner_seen or {}

    local function scan(root, depth)
        if depth > 3 then return nil end
        if type(root) ~= "table" then return nil end
        local tr = root.TestRunner or root.TestRegistry
        if type(tr) == "table" and type(tr.getTests) == "function" then
            local ok, reg = pcall(tr.getTests)
            if ok and type(reg) == "table" then
                local out = {}
                local found = 0
                for tname, t in pairs(reg) do
                    if not _pz_runner_seen[tname] then
                        if type(t) == "function" then
                            out[tname] = t
                            found = found + 1
                        elseif type(t) == "table" and type(t.run) == "function" then
                            out[tname] = function()
                                t:run()
                                if type(t.validate) == "function" then
                                    return t:validate()
                                end
                                return true
                            end
                            found = found + 1
                        end
                    end
                end
                if found > 0 then return out end
            end
        end
        for _, v in pairs(root) do
            if type(v) == "table" and v ~= root then
                local inner = scan(v, depth + 1)
                if inner then return inner end
            end
        end
        return nil
    end

    local discovered = scan(_G, 0)
    if discovered then
        for tname in pairs(discovered) do _pz_runner_seen[tname] = true end
        testTable = discovered
    end
end

if type(testTable) ~= "table" then
    return 0, 0, 0, 0, "No test table returned by test file (use `return tests` or PZTestKit.adoptRegistry)"
end

-- Collect and sort test names for deterministic order.
-- Honor `_pz_filter` (Lua pattern) if set by the runner (via --filter CLI).
local names = {}
local filterPattern = _pz_filter
-- `_pz_only` (--only): exact test names selected for THIS file — smart
-- reruns pick tests by impact, which a pattern can't express.
local only = _pz_only
for name in pairs(testTable) do
    if only then
        if only[name] then table.insert(names, name) end
    elseif filterPattern then
        if name:find(filterPattern) then
            table.insert(names, name)
        end
    else
        table.insert(names, name)
    end
end
table.sort(names)

local total, passed, failed, errors, skipped = 0, 0, 0, 0, 0
local details = {}

-- Per-test records for JUnit XML / --report-json. Each entry: { name, status, message, ms?, output? }.
-- status = "pass" | "fail" | "error" | "skip".
local records = {}

local function isSkipMarker(v)
    return type(v) == "table" and v.__pztestkit_skip == true
end

-- ============================================================================
-- PER-TEST SANDBOX (Events + context)
-- ============================================================================
-- Listener registrations and context stubs leak: a test that Events.X.Add()s
-- a handler, or hand-stubs _G.isServer and then errors before restoring,
-- silently poisons every later test in the file (the VPS Tier 2 incident
-- class — a suite reporting damage the suite itself did). The executor now
-- owns the discipline: snapshot before each test, restore after, in every
-- outcome. Load-time registrations (mod files ran before this file) are in
-- the first snapshot, so they persist — only what a TEST adds is scoped.
-- pairs(Events) sees only rawset keys, which is exactly the touched set
-- (the __index autovivifier rawsets on first access).
local function snapshotSandbox()
    local snap = { events = {}, isServer = _G.isServer, isClient = _G.isClient }
    if type(Events) == "table" then
        for evName, evt in pairs(Events) do
            if type(evt) == "table" and type(evt._listeners) == "table" then
                local copy = {}
                for i, fn in ipairs(evt._listeners) do copy[i] = fn end
                snap.events[evName] = copy
            end
        end
    end
    return snap
end

local function restoreSandbox(snap)
    _G.isServer, _G.isClient = snap.isServer, snap.isClient
    if type(Events) == "table" then
        for evName, evt in pairs(Events) do
            if type(evt) == "table" and type(evt._listeners) == "table" then
                local saved = snap.events[evName]
                if saved then
                    local fresh = {}
                    for i, fn in ipairs(saved) do fresh[i] = fn end
                    evt._listeners = fresh
                else
                    -- Event first touched during the test: unscope it.
                    evt._listeners = {}
                end
            end
        end
    end
end

local assertMarker = PZTestKit and PZTestKit.ASSERT_FAIL_MARKER or "__PZTK_ASSERT_FAIL__"

for _, name in ipairs(names) do
    total = total + 1

    local sandbox = snapshotSandbox()

    -- Reset player state between tests
    _pz_player._primaryHand = nil
    _pz_player._secondaryHand = nil
    _pz_player._traits = {}
    _pz_player._isOutside = false
    _pz_player._bloodLevel = 0
    _pz_player_inventory._items = {}
    _pz_player_moddata = {}

    -- Reset per-test assertion accounting + fixture miss ledger
    if PZTestKit then
        PZTestKit._assertFails = 0
        PZTestKit._assertPasses = 0
        PZTestKit._fixtureMisses = {}
    end

    local record = { name = name, status = "pass", message = "" }
    local startMs = _pz_now_ms and _pz_now_ms() or nil
    if _pz_cov_per_test then _pz_cov_test = {} end

    -- Capture everything the test prints (mod Assert libraries report the
    -- actual failing assertion via print, e.g. "[MyMod:TEST] [FAIL] ...").
    -- On failure, the captured FAIL lines become the record message — so the
    -- runner's failure digest and JUnit XML say WHICH assertion failed, not
    -- just "assertion returned false".
    local captured = {}
    local basePrint = print
    print = function(...)
        local args = { ... }
        local parts = {}
        for i = 1, #args do parts[i] = tostring(args[i]) end
        captured[#captured + 1] = table.concat(parts, "\t")
        return basePrint(...)
    end

    local function failLines()
        local hits = {}
        for _, line in ipairs(captured) do
            if line:find("FAIL", 1, true) then hits[#hits + 1] = line end
        end
        if #hits == 0 then
            -- No FAIL-marked lines: fall back to the tail of the output.
            for i = math.max(1, #captured - 2), #captured do
                hits[#hits + 1] = captured[i]
            end
        end
        return table.concat(hits, "\n")
    end

    -- Fixture-miss ledger (PZTestKit.trackMisses): on failure/error, name
    -- the members that were looked up but absent — Kahlua's "Object tried
    -- to call nil" never says which method, so this is the diagnosis.
    local function missLedger()
        local misses = PZTestKit and PZTestKit._fixtureMisses
        if not misses then return "" end
        local keys = {}
        for k in pairs(misses) do keys[#keys + 1] = k end
        if #keys == 0 then return "" end
        table.sort(keys)
        return "fixture lookups that returned nil: " .. table.concat(keys, ", ")
    end

    -- Kahlua's pcall returns (ok, err, stacktrace) — the third value carries
    -- the Lua-side stack for runtime errors whose tostring is just a bare
    -- Java class name ("java.lang.RuntimeException" tells an agent nothing).
    local ok, err, trace = pcall(function()
        local result = testTable[name]()
        if isSkipMarker(result) then
            skipped = skipped + 1
            record.status = "skip"
            record.message = result.message or "skipped"
            return
        end
        -- Assertion accounting: a test fails when ANY kit assert failed
        -- during its run, or when it explicitly returned false. A nil
        -- return with clean asserts PASSES — forgetting to `return` the
        -- final Assert is no longer a (silent, unexplained) failure, and a
        -- mid-body assert failure can't hide behind a passing returned one.
        -- Mod-native test registries (adoptRegistry/TestRunner) that don't
        -- use the kit Assert still fail via their returned boolean.
        local kitFails = (PZTestKit and PZTestKit._assertFails) or 0
        if kitFails == 0 and result ~= false then
            passed = passed + 1
        else
            failed = failed + 1
            record.status = "fail"
            local lines = failLines()
            if lines == "" then
                lines = (result == false)
                    and "test returned false (no kit assert failed; hand-rolled check?)"
                    or "assertion failed"
            end
            local ledger = missLedger()
            if ledger ~= "" then lines = lines .. "\n" .. ledger end
            record.message = lines
            if #details < 10 then
                table.insert(details, name .. ": FAILED")
            end
        end
    end)
    print = basePrint
    restoreSandbox(sandbox)

    if not ok and tostring(err):find(assertMarker, 1, true) then
        -- A kit assert threw: this is a FAILURE (the [FAIL] line already
        -- printed says which assertion), not a runtime error.
        failed = failed + 1
        record.status = "fail"
        local lines = failLines()
        if lines == "" then lines = "assertion failed" end
        local ledger = missLedger()
        if ledger ~= "" then lines = lines .. "\n" .. ledger end
        record.message = lines
        if #details < 10 then
            table.insert(details, name .. ": FAILED")
        end
    elseif not ok then
        errors = errors + 1
        record.status = "error"
        local msg = tostring(err):gsub("^%s+", "")
        if trace ~= nil and tostring(trace) ~= "" then
            msg = msg .. "\n" .. tostring(trace)
        end
        local lines = failLines()
        if lines ~= "" then
            msg = msg .. "\n" .. lines
        end
        local ledger = missLedger()
        if ledger ~= "" then
            msg = msg .. "\n" .. ledger
        end
        record.message = msg
        if #details < 10 then
            table.insert(details, name .. ": " .. tostring(err))
        end
    end
    -- Report-only extras (--report-json): wall time and what the test
    -- printed. Output is capped so a chatty mod can't balloon the report.
    if startMs then record.ms = _pz_now_ms() - startMs end
    -- Per-test coverage: { [path] = {line, ...} } of what this test ran.
    if _pz_cov_per_test and _pz_cov_test then
        local cov = {}
        for id, lines in pairs(_pz_cov_test) do
            local e = _pz_cov_files[id]
            if e then
                local l = {}
                for ln in pairs(lines) do l[#l + 1] = ln end
                cov[e.file] = l
            end
        end
        record.cov = cov
        _pz_cov_test = nil
    end
    if #captured > 0 then
        local first = math.max(1, #captured - 199)
        local kept = {}
        for i = first, #captured do kept[#kept + 1] = captured[i] end
        if first > 1 then table.insert(kept, 1, "... (" .. (first - 1) .. " earlier lines dropped)") end
        record.output = table.concat(kept, "\n")
    end
    table.insert(records, record)
end

_pz_last_test_records = records
_pz_last_skipped_count = skipped

local detailStr = #details > 0 and table.concat(details, "\n") or ""
return total, passed, failed, errors, detailStr
