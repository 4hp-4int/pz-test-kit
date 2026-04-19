--[[
    PZ Test Kit — test-file wrapper
    ================================
    Loads a single test file's source and captures its return value into
    `_pz_last_return` so test_executor.lua can pick it up. Input:
        _pz_test_source   — verbatim test file source (context guards stripped)
        _pz_test_name     — chunk name for stack traces (e.g. test file path)
]]

if type(_pz_test_source) ~= "string" then
    error("_pz_test_source not set", 0)
end

local chunk, err = loadstring(
    "return (function()\n" .. _pz_test_source .. "\nend)()",
    _pz_test_name or "test_file")
if not chunk then
    error("test file compile failed: " .. tostring(err), 0)
end
_pz_last_return = chunk()
