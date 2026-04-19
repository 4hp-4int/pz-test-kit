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
for name in pairs(testTable) do
    if filterPattern then
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

-- Per-test records for JUnit XML output. Each entry: { name, status, message }.
-- status = "pass" | "fail" | "error" | "skip".
local records = {}

local function isSkipMarker(v)
    return type(v) == "table" and v.__pztestkit_skip == true
end

for _, name in ipairs(names) do
    total = total + 1

    -- Reset player state between tests
    _pz_player._primaryHand = nil
    _pz_player._secondaryHand = nil
    _pz_player._traits = {}
    _pz_player._isOutside = false
    _pz_player._bloodLevel = 0
    _pz_player_inventory._items = {}
    _pz_player_moddata = {}

    local record = { name = name, status = "pass", message = "" }
    local ok, err = pcall(function()
        local result = testTable[name]()
        if isSkipMarker(result) then
            skipped = skipped + 1
            record.status = "skip"
            record.message = result.message or "skipped"
        elseif result then
            passed = passed + 1
        else
            failed = failed + 1
            record.status = "fail"
            record.message = "assertion returned false"
            if #details < 10 then
                table.insert(details, name .. ": FAILED")
            end
        end
    end)

    if not ok then
        errors = errors + 1
        record.status = "error"
        record.message = tostring(err)
        if #details < 10 then
            table.insert(details, name .. ": " .. tostring(err))
        end
    end
    table.insert(records, record)
end

_pz_last_test_records = records
_pz_last_skipped_count = skipped

local detailStr = #details > 0 and table.concat(details, "\n") or ""
return total, passed, failed, errors, detailStr
