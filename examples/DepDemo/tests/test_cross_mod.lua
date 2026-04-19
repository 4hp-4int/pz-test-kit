-- This test uses MyMod's API even though we're NOT in MyMod's directory.
-- pz-test-kit resolved the require via the dependency declared in pz-test.lua.

local Assert = PZTestKit.Assert
local tests = {}

tests["cross_mod_require_resolves"] = function()
    return Assert.notNil(MyMod, "MyMod namespace loaded from dependency")
end

tests["cross_mod_api_callable"] = function()
    return Assert.nearEqual(MyMod.getBuffAmount(100), 0.5, 0.001,
        "MyMod.getBuffAmount usable from a dependent mod")
end

return tests
