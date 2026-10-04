--[[
    PZ Test Kit — fidelity call counting (--fidelity)
    ==================================================
    Wraps the global functions a surface layer just installed (mock / vanilla /
    engine) so the run can report which of them the suite actually CALLED.
    "The suite leans on mock X 4,000 times" is the ranked list of where a green
    run proves the least about the real game.

    Input (set by the Java runner before each load):
        _pz_fid_env    the env table (Kahlua has no _G here)
        _pz_fid_names  { "name", ... } globals to wrap
        _pz_fid_layer  layer label for those names
    Output: _pz_fid_calls[name] = count (per env == per test file).

    Wrapping happens right after each layer installs, so mod code that caches
    `local getPlayer = getPlayer` at load still captures the counting version.
]]

_pz_fid_calls = _pz_fid_calls or {}

local G, names = _pz_fid_env, _pz_fid_names
if type(G) == "table" and type(names) == "table" then
    local calls = _pz_fid_calls
    for i = 1, #names do
        local name = names[i]
        local f = rawget(G, name)
        if type(f) == "function" then
            rawset(G, name, function(...)
                calls[name] = (calls[name] or 0) + 1
                return f(...)
            end)
        end
    end
end
_pz_fid_names = nil
