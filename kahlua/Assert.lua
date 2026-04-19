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

local function pass(label, ...) print(string.format("  [PASS] " .. label, ...)); return true end
local function fail(label, ...) print(string.format("  [FAIL] " .. label, ...)); return false end

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

print("[PZTestKit] Assert library loaded")
return PZTestKit.Assert
