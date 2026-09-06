--[[
    PZ Test Kit — Assert Library
    =============================
    Rich assertions with auto-generated pass/fail messages.
    All methods return true on pass, false on fail.

    Usage:
        local Assert = PZTestKit.Assert
        Assert.equal(actual, expected, "damage value")
        Assert.nearEqual(weapon:getMaxDamage(), 2.2, 0.01, "maxDamage")
        Assert.greater(newCrit, originalCrit, "crit increased")
        Assert.notNil(weapon, "weapon spawned")
]]

PZTestKit = PZTestKit or {}
PZTestKit._testFiles = PZTestKit._testFiles or {}
PZTestKit.Assert = {}

-- No-op registerTests for offline — Kahlua runner uses _pz_last_return instead
if not PZTestKit.registerTests then
    function PZTestKit.registerTests() end
end

--- Let a mod hand the kit a function that returns the test table on demand.
--- Use for TestRunner.registerSync-style mods that don't `return tests`.
--- Call ONCE from your mod's TestRunner bridge.
---@param fn function Returns the test-name → test-fn table
function PZTestKit.adoptRegistry(fn)
    PZTestKit._adoptedRegistry = fn
end

local Assert = PZTestKit.Assert

local function fmt(v)
    if v == nil then return "nil" end
    if type(v) == "string" then return '"' .. v .. '"' end
    if type(v) == "number" then
        if v == math.floor(v) then return tostring(v) end
        return string.format("%.4f", v)
    end
    return tostring(v)
end

-- Per-test assertion accounting. The executor resets these before each test
-- and fails a test when ANY kit assert failed — regardless of what the test
-- body returns. Kills two footguns at once: a test that forgets to `return`
-- its final Assert (previously counted FAILED with all-green asserts and no
-- explanation), and a test whose mid-body assert failed but whose final
-- returned assert passed (previously a silent partial pass).
PZTestKit._assertFails = 0
PZTestKit._assertPasses = 0

local function pass(label, ...)
    PZTestKit._assertPasses = PZTestKit._assertPasses + 1
    print(string.format("  [PASS] " .. label, ...)); return true
end

-- A failed assert THROWS (caught by the executor, recorded as a FAIL with
-- the printed [FAIL] line as the message). Stopping at the first failure is
-- the point: the old return-false style let the test body keep running on
-- state the failed assert just disproved, and the real failure drowned in
-- cascading FAILs or a confusing nil error three lines later. The classic
-- guard chain (`if not Assert.equal(...) then return false end`) still
-- works — the guard just never sees false anymore. A mod that genuinely
-- needs the old semantics sets `assert_style = "return"` in pz-test.lua.
PZTestKit.ASSERT_FAIL_MARKER = "__PZTK_ASSERT_FAIL__"
local function fail(label, ...)
    PZTestKit._assertFails = PZTestKit._assertFails + 1
    print(string.format("  [FAIL] " .. label, ...))
    if _pz_assert_style ~= "return" then
        error(PZTestKit.ASSERT_FAIL_MARKER)
    end
    return false
end

function Assert.equal(actual, expected, label)
    label = label or ""
    if actual == expected then return pass("%s: %s == %s", label, fmt(actual), fmt(expected))
    else return fail("%s: expected %s, got %s", label, fmt(expected), fmt(actual)) end
end

function Assert.notEqual(actual, unexpected, label)
    label = label or ""
    if actual ~= unexpected then return pass("%s: %s ~= %s", label, fmt(actual), fmt(unexpected))
    else return fail("%s: expected not %s, got %s", label, fmt(unexpected), fmt(actual)) end
end

function Assert.nearEqual(actual, expected, tolerance, label)
    tolerance = tolerance or 0.001; label = label or ""
    if actual == nil or expected == nil then
        if actual == expected then return pass("%s: both nil", label)
        else return fail("%s: expected ~%s (tol %s), got %s", label, fmt(expected), fmt(tolerance), fmt(actual)) end
    end
    if math.abs(actual - expected) <= tolerance then
        return pass("%s: %s ~= %s (tol %s)", label, fmt(actual), fmt(expected), fmt(tolerance))
    else
        return fail("%s: expected ~%s (tol %s), got %s (diff %s)", label, fmt(expected), fmt(tolerance), fmt(actual), fmt(math.abs(actual - expected)))
    end
end

function Assert.greater(actual, threshold, label)
    label = label or ""
    if actual > threshold then return pass("%s: %s > %s", label, fmt(actual), fmt(threshold))
    else return fail("%s: expected > %s, got %s", label, fmt(threshold), fmt(actual)) end
end

function Assert.greaterEq(actual, threshold, label)
    label = label or ""
    if actual >= threshold then return pass("%s: %s >= %s", label, fmt(actual), fmt(threshold))
    else return fail("%s: expected >= %s, got %s", label, fmt(threshold), fmt(actual)) end
end

function Assert.less(actual, threshold, label)
    label = label or ""
    if actual < threshold then return pass("%s: %s < %s", label, fmt(actual), fmt(threshold))
    else return fail("%s: expected < %s, got %s", label, fmt(threshold), fmt(actual)) end
end

function Assert.lessEq(actual, threshold, label)
    label = label or ""
    if actual <= threshold then return pass("%s: %s <= %s", label, fmt(actual), fmt(threshold))
    else return fail("%s: expected <= %s, got %s", label, fmt(threshold), fmt(actual)) end
end

function Assert.notNil(value, label)
    label = label or "value"
    if value ~= nil then return pass("%s: not nil", label)
    else return fail("%s: expected non-nil, got nil", label) end
end

function Assert.isNil(value, label)
    label = label or "value"
    if value == nil then return pass("%s: is nil", label)
    else return fail("%s: expected nil, got %s", label, fmt(value)) end
end

function Assert.isTrue(value, label)
    label = label or "condition"
    if value == true then return pass("%s: true", label)
    else return fail("%s: expected true, got %s", label, fmt(value)) end
end

function Assert.isFalse(value, label)
    label = label or "condition"
    if value == false then return pass("%s: false", label)
    else return fail("%s: expected false, got %s", label, fmt(value)) end
end

function Assert.tableHas(tbl, key, label)
    label = label or "table"
    if type(tbl) ~= "table" then return fail("%s: expected table, got %s", label, type(tbl)) end
    if tbl[key] ~= nil then return pass("%s: has key '%s'", label, tostring(key))
    else return fail("%s: missing key '%s'", label, tostring(key)) end
end

function Assert.tableNotHas(tbl, key, label)
    label = label or "table"
    if type(tbl) ~= "table" then return fail("%s: expected table, got %s", label, type(tbl)) end
    if tbl[key] == nil then return pass("%s: no key '%s'", label, tostring(key))
    else return fail("%s: unexpected key '%s' = %s", label, tostring(key), fmt(tbl[key])) end
end

-- ============================================================================
-- TEST-WRITING HELPERS (leak-proof patching, spies, context stubs)
-- ============================================================================
-- Born from a real incident: a spy restored *after* the action leaked when
-- the action threw, and poisoned the next test in (sorted) run order. Every
-- helper here restores in all outcomes and re-raises the original error.
-- Same scoped-override shape as Fixtures.withSandbox.

--- Replace tbl[key] for the duration of fn; ALWAYS restores; re-raises on
--- error. Returns fn's first return value.
---   PZTestKit.withPatch(SaucedCarts, "updateCartVisual", spyFn, function()
---       return SaucedCarts.performCartTransfer(...)
---   end)
function PZTestKit.withPatch(tbl, key, replacement, fn)
    local original = tbl[key]
    tbl[key] = replacement
    local ok, result = pcall(fn)
    tbl[key] = original
    if not ok then error(result, 0) end
    return result
end

--- Recording stub. Returns (fn, calls): fn appends its args to calls on
--- every invocation, then delegates to impl (or returns true).
---   local spyFn, calls = PZTestKit.spy()
---   PZTestKit.withPatch(SaucedCarts, "updateCartVisual", spyFn, body)
---   Assert.equal(#calls, 1, "one refresh")
function PZTestKit.spy(impl)
    local calls = {}
    local fn = function(...)
        calls[#calls + 1] = { n = select("#", ...), ... }
        if impl then return impl(...) end
        return true
    end
    return fn, calls
end

--- Run fn with isServer()/isClient() stubbed to a named context; ALWAYS
--- restores; re-raises on error. The harness defaults to isClient()==true,
--- which silently skips `if not isClient()` server/SP branches — every test
--- exercising one needs this (or hand-rolled stubs).
--- Modes: "sp" (false,false) | "server"/"dedi" (true,false)
---        | "client" (false,true) | "host" (true,true)
function PZTestKit.withContext(mode, fn)
    local matrix = {
        sp = { false, false }, server = { true, false },
        dedi = { true, false }, client = { false, true },
        host = { true, true },
    }
    local ctx = matrix[mode]
    if not ctx then error("PZTestKit.withContext: unknown mode '" .. tostring(mode) .. "'", 2) end
    local oldServer, oldClient = _G.isServer, _G.isClient
    _G.isServer = function() return ctx[1] end
    _G.isClient = function() return ctx[2] end
    local ok, result = pcall(fn)
    _G.isServer, _G.isClient = oldServer, oldClient
    if not ok then error(result, 0) end
    return result
end

--- Wrap a hand-rolled (plain-table) fixture so lookups of MISSING members
--- get recorded. Kahlua's "Object tried to call nil" doesn't name the
--- method; the executor prints this ledger on test failure/error instead,
--- turning fixture-gap whack-a-mole into a one-shot diagnosis. Existence
--- guards (`if obj.method then`) behave identically — __index only fires
--- for absent keys and still yields nil.
---   local sq = PZTestKit.trackMisses(makeSquare(), "square")
function PZTestKit.trackMisses(tbl, label)
    PZTestKit._fixtureMisses = PZTestKit._fixtureMisses or {}
    local misses = PZTestKit._fixtureMisses
    label = label or "fixture"
    setmetatable(tbl, {
        __index = function(_, key)
            misses[label .. "." .. tostring(key)] = true
            return nil
        end,
    })
    return tbl
end

print("[PZTestKit] Assert library loaded")
return PZTestKit.Assert
