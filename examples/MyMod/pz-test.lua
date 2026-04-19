--[[
    MyMod — PZ Test Kit configuration (example)

    This file is optional. With no config, the kit still works via zero-config
    auto-discovery — MyMod's tests already pass without this file.

    Config is useful when:
      - Your tests assume modules are preloaded (not required by the test itself)
      - Your mod reads SandboxVars with no nil check
      - You need a non-default weapon_scripts path
      - You have tests that depend on a mod whose require() the kit can't see
]]

return {
    -- Preload these before any test file. Equivalent to a test file doing
    -- `require "MyMod/Core"`, but you don't have to repeat it everywhere.
    preload = {
        "MyMod/Core",
    },

    -- SandboxVars defaults. If your mod reads `SandboxVars.MyMod.Setting`
    -- without a nil check, set the expected default here.
    sandbox = {
        MyMod = {
            EnableBuffs = true,
            BuffMultiplier = 1.0,
        },
    },

    -- Extra core-PZ modules to stub as nil. Default stubs cover ISUI/* and
    -- common Iso* modules — add here if your mod requires something else.
    -- stub_requires = { "YourCoreModule" },

    -- Optional: where to find the weapon scripts file. Default is
    -- `<modRoot>/weapon_scripts.lua`.
    -- weapon_scripts = "tests/weapon_scripts.lua",
}
