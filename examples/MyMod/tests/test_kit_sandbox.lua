--[[
    Kit self-tests: throwing asserts + the per-test sandbox.

    These pin the executor's own guarantees, so a regression in either
    mechanism fails the kit's example suite instead of surfacing as a
    mystery in some mod's tests months later.

    ORDER MATTERS for the sandbox pair: names sort alphabetically, so
    sandbox_a runs first and deliberately leaks; sandbox_b proves the
    executor cleaned up between them.
]]

local Assert = PZTestKit.Assert

local tests = {}

tests["sandbox_a_leaks_a_listener_and_a_context_stub"] = function()
    Events.OnKitSandboxProbe.Add(function() end)
    _G.isServer = function() return true end
    if not Assert.equal(#Events.OnKitSandboxProbe._listeners, 1, "listener registered") then
        return false
    end
    return Assert.isTrue(isServer(), "context stubbed")
end

tests["sandbox_b_sees_clean_state"] = function()
    if not Assert.equal(#Events.OnKitSandboxProbe._listeners, 0,
        "previous test's listener was unscoped") then
        return false
    end
    return Assert.isFalse(isServer(), "previous test's context stub was restored")
end

tests["throwing_assert_stops_the_test_body"] = function()
    local reached = false
    local ok, err = pcall(function()
        Assert.equal(1, 2, "deliberate mismatch (the FAIL line above is expected)")
        reached = true
    end)
    -- The deliberate failure bumped the accounting; undo it so THIS test's
    -- verdict reflects only the assertions below.
    PZTestKit._assertFails = PZTestKit._assertFails - 1

    if not Assert.isFalse(reached, "body stopped at the failed assert") then return false end
    if not Assert.isFalse(ok, "failed assert threw") then return false end
    return Assert.isTrue(
        tostring(err):find(PZTestKit.ASSERT_FAIL_MARKER, 1, true) ~= nil,
        "error carries the assert-fail marker")
end

tests["passing_asserts_still_return_true"] = function()
    -- The guard-chain style must keep working: a passing assert returns
    -- true, so `if not Assert.x(...) then return false end` is a no-op.
    local r = Assert.equal(1, 1, "passing assert")
    return Assert.isTrue(r, "pass returned true")
end

return tests
