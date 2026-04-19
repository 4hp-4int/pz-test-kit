--[[
    PZ Test Kit — pz-test.lua config loader wrapper
    ================================================
    Runs the mod's pz-test.lua source as an expression and captures its
    returned table into the global `_pz_config`. Input (set by Java before
    loading this):
        _pz_config_source — the verbatim source of <modRoot>/pz-test.lua

    Errors compile/run failures into a warning so a broken config doesn't
    abort the test run.
]]

if type(_pz_config_source) ~= "string" then return end

local chunk, err = loadstring(
    "return (function()\n" .. _pz_config_source .. "\nend)()",
    "pz-test.lua")
if not chunk then
    print("  WARNING: pz-test.lua compile failed: " .. tostring(err))
    return
end
local ok, result = pcall(chunk)
if not ok then
    print("  WARNING: pz-test.lua runtime error: " .. tostring(result))
    return
end
_pz_config = result
