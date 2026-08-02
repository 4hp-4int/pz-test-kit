--[[
    PZ Test Kit — self-tests for the DX helpers (2026-08)
    =====================================================
    Covers PZTestKit.withPatch / spy / withContext / trackMisses and the
    executor's assertion accounting. Born from the SaucedCarts visual-fix
    session: a leaked spy poisoned the next test, a forgotten `return`
    counted a green test as FAILED with no explanation, and fixture gaps
    surfaced one opaque "Object tried to call nil" at a time.
]]

if isServer() and not isClient() then return end
if not (PZTestKit and PZTestKit.Assert) then return end

local Assert = PZTestKit.Assert

local tests = {}

-- ----------------------------------------------------------------------------
-- withPatch
-- ----------------------------------------------------------------------------

tests["withPatch_replaces_and_restores"] = function()
    local host = { value = function() return "original" end }
    local seen
    local result = PZTestKit.withPatch(host, "value", function() return "patched" end, function()
        seen = host.value()
        return "body-result"
    end)
    Assert.equal(seen, "patched", "replacement active inside body")
    Assert.equal(result, "body-result", "body return value passes through")
    return Assert.equal(host.value(), "original", "original restored after body")
end

tests["withPatch_restores_when_body_throws"] = function()
    local host = { value = "original" }
    local ok, err = pcall(function()
        PZTestKit.withPatch(host, "value", "patched", function()
            error("boom")
        end)
    end)
    Assert.isFalse(ok, "error propagates out of withPatch")
    Assert.isTrue(tostring(err):find("boom") ~= nil, "original error preserved")
    -- THE regression this helper exists for: restore must run on the error
    -- path, or the patch leaks into whichever test runs next.
    return Assert.equal(host.value, "original", "patch restored despite the throw")
end

-- ----------------------------------------------------------------------------
-- spy
-- ----------------------------------------------------------------------------

tests["spy_records_calls_and_defaults_true"] = function()
    local fn, calls = PZTestKit.spy()
    local r1 = fn("a", 1)
    fn("b", 2, nil, 4)
    Assert.isTrue(r1, "spy returns true with no impl")
    Assert.equal(#calls, 2, "two calls recorded")
    Assert.equal(calls[1][1], "a", "first call first arg")
    Assert.equal(calls[2][2], 2, "second call second arg")
    return Assert.equal(calls[2].n, 4, "arg count preserved through nil holes")
end

tests["spy_delegates_to_impl"] = function()
    local fn, calls = PZTestKit.spy(function(x) return x * 2 end)
    local r = fn(21)
    Assert.equal(r, 42, "impl return value passes through")
    return Assert.equal(#calls, 1, "call still recorded")
end

-- ----------------------------------------------------------------------------
-- withContext
-- ----------------------------------------------------------------------------

tests["withContext_modes_and_restore"] = function()
    local baselineServer, baselineClient = isServer(), isClient()

    local inServer = PZTestKit.withContext("server", function()
        return { s = isServer(), c = isClient() }
    end)
    Assert.isTrue(inServer.s, "server mode: isServer true")
    Assert.isFalse(inServer.c, "server mode: isClient false")

    local inSp = PZTestKit.withContext("sp", function()
        return { s = isServer(), c = isClient() }
    end)
    Assert.isFalse(inSp.s, "sp mode: isServer false")
    Assert.isFalse(inSp.c, "sp mode: isClient false")

    Assert.equal(isServer(), baselineServer, "isServer restored")
    return Assert.equal(isClient(), baselineClient, "isClient restored")
end

tests["withContext_restores_when_body_throws"] = function()
    local baselineServer, baselineClient = isServer(), isClient()
    local ok = pcall(function()
        PZTestKit.withContext("server", function() error("boom") end)
    end)
    Assert.isFalse(ok, "error propagates")
    Assert.equal(isServer(), baselineServer, "isServer restored despite throw")
    return Assert.equal(isClient(), baselineClient, "isClient restored despite throw")
end

tests["withContext_rejects_unknown_mode"] = function()
    local ok = pcall(function() PZTestKit.withContext("mainframe", function() end) end)
    return Assert.isFalse(ok, "unknown mode errors loudly")
end

-- ----------------------------------------------------------------------------
-- trackMisses
-- ----------------------------------------------------------------------------

tests["trackMisses_records_absent_members_only"] = function()
    local fixture = PZTestKit.trackMisses({ present = "yes" }, "myfixture")
    Assert.equal(fixture.present, "yes", "present members unaffected")
    Assert.isNil(fixture.setIgnoreRemoveSandbox, "absent member still nil (guards keep working)")
    local _ = fixture.anotherMissingOne
    local misses = PZTestKit._fixtureMisses or {}
    Assert.isTrue(misses["myfixture.setIgnoreRemoveSandbox"] == true, "miss recorded with fixture label")
    Assert.isTrue(misses["myfixture.anotherMissingOne"] == true, "second miss recorded")
    return Assert.isTrue(misses["myfixture.present"] == nil, "present member not recorded")
end

-- ----------------------------------------------------------------------------
-- Assertion accounting (executor behavior)
-- ----------------------------------------------------------------------------

-- This test intentionally does NOT return its asserts. Pre-accounting, a
-- nil-returning test counted FAILED even with all-green asserts (with no
-- explanation in the digest) — so this test PASSING is itself the
-- regression check for the executor change.
tests["nil_return_with_green_asserts_passes"] = function()
    Assert.isTrue(true, "an assert that passes")
    Assert.equal(1 + 1, 2, "another passing assert")
    -- deliberately no return
end

return tests
