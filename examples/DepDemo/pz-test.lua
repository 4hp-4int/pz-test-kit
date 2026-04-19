-- Example: a mod that depends on MyMod (sibling directory).
-- pz-test-kit indexes ../MyMod/media/lua/ alongside this mod, so
-- `require "MyMod/Core"` resolves across the dependency.
return {
    dependencies = {
        "../MyMod",
        -- or: { path = "../MyMod", name = "MyMod" },
    },
    preload = {
        "MyMod/Core",   -- pulled in from the dependency
    },
}
