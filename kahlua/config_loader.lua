--[[
    PZ Test Kit — Config Loader
    ============================
    Processes the configuration table returned by `<modRoot>/pz-test.lua`
    (if present) to apply:

      - SandboxVars defaults (so tests don't crash on nil sandbox reads)
      - Preloaded modules (so tests that assume module X is loaded see it)
      - Additional stubbed requires (mods that require core-PZ Lua not in our
        default stub list)
      - Custom test_file_patterns (Java-side)
      - Custom test_paths (Java-side)
      - Custom weapon_scripts path (Java-side)

    The config is written to `_pz_config` by the Java runner before this file
    loads. If no config file was found, `_pz_config` is nil and this file is
    effectively a no-op.

    CONFIG FORMAT (pz-test.lua at mod root):
    ----------------------------------------
        return {
            preload = {
                "VorpallySauced/Core",
                "VorpallySauced/WeaponTraitEffects",
            },

            sandbox = {
                VorpallySauced = {
                    EnableMod = true,
                    TraitEffectStrength = 100,
                },
            },

            stub_requires = {
                "zombie/Lua/LuaEventManager",
            },

            -- Read by the Java runner: loads the mod's real translation bundle
            -- (and its `dependencies`') so getText behaves like Translator —
            -- the loader's "%1" -> "%1$s" pass, String.formatted() on every
            -- fetch, and the WARN an unfed specifier produces. See
            -- kahlua/translate.lua for the test API. Accepts a language code
            -- ("EN"), true (== "EN"), or a path to a directory of .json files.
            translate = "EN",

            -- These are read by the Java runner BEFORE this file loads:
            weapon_scripts    = "tests/weapon_scripts.lua",
            test_paths        = { "media/lua/client/MyMod/Tests" },
            test_file_patterns = { "test_*.lua", "*Tests.lua" },
        }
]]

if type(_pz_config) ~= "table" then
    -- No config file — keep defaults
    print("[PZTestKit] No pz-test.lua found, using defaults")
    return
end

local cfg = _pz_config

local function countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- ── 0. Strict mock mode toggle ──────────────────────────────────────────────
-- Opt-in: set `strict_mocks = true` in pz-test.lua to reject private-field
-- writes on mock items (simulates real PZ Java-object behavior). Default off
-- to preserve backward compat with mods built against lax mocks.
if cfg.strict_mocks == true then
    _pz_strict_mocks = true
    print("[PZTestKit] Strict mock mode enabled by config")
elseif cfg.strict_mocks == false then
    _pz_strict_mocks = false
end

-- ── 0c. Assert style ────────────────────────────────────────────────────────
-- Kit asserts throw on failure (stop-at-first-failure). A mod that needs the
-- legacy return-false semantics opts out here.
if cfg.assert_style == "return" then
    _pz_assert_style = "return"
    print("[PZTestKit] Legacy return-style asserts enabled by config")
end

-- ── 0d. Ambient context ─────────────────────────────────────────────────────
-- The harness defaults to MP-client (isClient()==true), which silently skips
-- `if not isClient()` server/SP branches — the mismatch that let an SP mod's
-- suite pass offline and self-destruct in game. `context = "sp"` (or
-- "server"/"client"/"host") sets the suite's ambient truth BEFORE mod files
-- load, so load-time guards see it too. Per-test needs still go through
-- PZTestKit.withContext. Never applied inside DualVMSim endpoints — the sim
-- assigns those contexts itself.
if type(cfg.context) == "string" then
    local isSimEndpoint = (_pz_client_index ~= nil) or (isServer and isServer())
    if not isSimEndpoint then
        local matrix = {
            sp = { false, false }, server = { true, false },
            dedi = { true, false }, client = { false, true },
            host = { true, true },
        }
        local ctx = matrix[cfg.context]
        if ctx then
            local s, c = ctx[1], ctx[2]
            _G.isServer = function() return s end
            _G.isClient = function() return c end
            print("[PZTestKit] Ambient context '" .. cfg.context .. "' set by config")
        else
            print("[PZTestKit] WARNING: unknown context '" .. tostring(cfg.context)
                .. "' in pz-test.lua (want sp|server|client|host) — keeping default")
        end
    end
end

-- ── 1. SandboxVars defaults ─────────────────────────────────────────────────
-- Deep-merge cfg.sandbox into SandboxVars. Existing values (set by mocks or
-- test code) are NOT overwritten — config is defaults, not overrides.
if type(cfg.sandbox) == "table" then
    SandboxVars = SandboxVars or {}
    for modName, settings in pairs(cfg.sandbox) do
        if type(settings) == "table" then
            SandboxVars[modName] = SandboxVars[modName] or {}
            for k, v in pairs(settings) do
                if SandboxVars[modName][k] == nil then
                    SandboxVars[modName][k] = v
                end
            end
        end
    end
    print("[PZTestKit] Applied sandbox defaults for " ..
        countKeys(cfg.sandbox) .. " mod(s)")
end

-- ── 2. Additional stubbed requires ──────────────────────────────────────────
if type(cfg.stub_requires) == "table" then
    _pz_stub_requires = _pz_stub_requires or {}
    local added = 0
    for _, name in ipairs(cfg.stub_requires) do
        if not _pz_stub_requires[name] then
            _pz_stub_requires[name] = true
            added = added + 1
        end
    end
    if added > 0 then
        print("[PZTestKit] Added " .. added .. " stub_requires from config")
    end
end

-- ── 3. Preload modules ──────────────────────────────────────────────────────
-- Requires each module in order. Errors during preload are fatal since
-- they indicate misconfiguration, not test failures.
if type(cfg.preload) == "table" then
    local loaded = 0
    for _, name in ipairs(cfg.preload) do
        require(name)
        loaded = loaded + 1
    end
    if loaded > 0 then
        print("[PZTestKit] Preloaded " .. loaded .. " module(s) from config")
    end
end


