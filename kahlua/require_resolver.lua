--[[
    PZ Test Kit — require() Resolver
    =================================
    Provides a PZ-style `require` that resolves module names ("MyMod/Core")
    against an index of Lua files pre-scanned from the mod's media/lua/ tree
    by the Java runner.

    HOW IT WORKS
    ------------
    At startup the Java runner walks media/lua/{shared,client,server}/**/*.lua,
    derives a require path from the relative path (e.g. "MyMod/Core.lua" →
    "MyMod/Core"), and populates these globals:
        _pz_module_sources[name] = <source string>
        _pz_module_files[name]   = <absolute file path for error messages>

    This file then installs a `require` function that:
      1. Checks `_pz_package_loaded` (same semantics as Lua's package.loaded)
      2. Looks up the name in `_pz_module_sources`
      3. Compiles + runs the source and caches the return value
      4. Returns nil for known core-PZ modules (ISToolTipInv, etc.) that a
         test harness doesn't provide

    RESOLUTION ORDER
    ----------------
    The Java scanner visits folders in this order and first-match wins:
        1. media/lua/shared/
        2. media/lua/client/
        3. media/lua/server/

    This mirrors real PZ require behavior where shared/ is authoritative.

    STUBBED MODULES
    ---------------
    Core PZ Lua (`ISUI/*`, `luautils`, `ISBaseObject`, `ISBaseTimedAction`) is
    stubbed to nil. Mod code that requires these just gets nil and should
    gate behavior with nil-checks or use the mock environment's stubs.

    Add your own stubs via:
        _pz_stub_requires["SomeCoreModule"] = true

    BEFORE you `require`.
]]

_pz_module_sources = _pz_module_sources or {}
_pz_module_files   = _pz_module_files   or {}
_pz_package_loaded = _pz_package_loaded or {}

-- Core PZ modules a standalone harness can't provide. require() returns nil
-- for these; mod code should treat them as absent or mock them explicitly.
_pz_stub_requires = _pz_stub_requires or {
    ["ISUI/ISToolTipInv"] = true,
    ["ISUI/ISPanel"] = true,
    ["ISUI/ISButton"] = true,
    ["ISUI/ISLabel"] = true,
    ["ISUI/ISModalDialog"] = true,
    ["ISUI/ISInventoryPaneContextMenu"] = true,
    ["ISUI/ISContextMenu"] = true,
    ["ISUI/ISRichTextPanel"] = true,
    ["ISUI/ISToolTip"] = true,
    ["ISUI/ISTextBox"] = true,
    ["ISUI/ISCollapsableWindow"] = true,
    ["luautils"] = true,
    ["ISBaseObject"] = true,
    ["ISBaseTimedAction"] = true,
    ["defines"] = true,
    ["recipecode"] = true,
    ["TimedActions/ISBaseTimedAction"] = true,
}

-- Sentinel for "require returned nil, don't reload"
local NIL_SENTINEL = {}

local function normalize(name)
    name = tostring(name)
    name = name:gsub("\\", "/")
    name = name:gsub("%.lua$", "")
    return name
end

local function countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Save any pre-existing require so we can fall back (stub requires get nil;
-- the Java runner doesn't install one by default).
local _orig_require = require

function require(name)
    if type(name) ~= "string" then
        error("require: expected string, got " .. type(name), 2)
    end

    name = normalize(name)

    -- Cache hit
    local cached = _pz_package_loaded[name]
    if cached ~= nil then
        if cached == NIL_SENTINEL then return nil end
        return cached
    end

    -- Stubbed core-PZ module
    if _pz_stub_requires[name] then
        _pz_package_loaded[name] = NIL_SENTINEL
        return nil
    end

    -- Try the mod-scanned index. Errors from chunk() propagate via Lua's
    -- built-in error mechanism, preserving file:line info in the trace.
    local source = _pz_module_sources[name]
    if source ~= nil then
        local chunkName = _pz_module_files[name] or name
        local chunk, cerr = loadstring(source, chunkName)
        if not chunk then
            error("compile error in '" .. name .. "': " .. tostring(cerr), 2)
        end
        -- IMPORTANT: set cache BEFORE running chunk, matching standard Lua
        -- require semantics. Cyclic requires get the partial module (may be
        -- nil or an empty table). This matches `package.loaded` behavior and
        -- prevents infinite recursion on circular deps.
        _pz_package_loaded[name] = NIL_SENTINEL
        local r = chunk()
        _pz_package_loaded[name] = (r ~= nil) and r or NIL_SENTINEL
        return r
    end

    -- Fallback to pre-existing require, if any
    if _orig_require then
        local o_ok, o_result = pcall(_orig_require, name)
        if o_ok then
            _pz_package_loaded[name] = (o_result ~= nil) and o_result or NIL_SENTINEL
            return o_result
        end
    end

    error("module '" .. name .. "' not found in module index (" ..
        countKeys(_pz_module_sources) ..
        " modules indexed). Add it to _pz_stub_requires to silently ignore.", 2)
end

-- Expose diagnostic helpers
_pz_require_stats = function()
    return {
        indexed = countKeys(_pz_module_sources),
        loaded = countKeys(_pz_package_loaded),
        stubbed = countKeys(_pz_stub_requires),
    }
end

print("[PZTestKit] require resolver installed (" ..
    countKeys(_pz_module_sources) .. " modules indexed)")
