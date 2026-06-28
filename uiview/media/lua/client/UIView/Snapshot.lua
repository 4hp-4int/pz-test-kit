--[[
    UIView — Snapshot capture API
    =============================
    Thin intent-revealing wrapper over Render.emit for golden-snapshot tests.
    A "snapshot" is just a named, deterministic display-list frame; the host
    comparator (snapshot.sh) diffs each emitted block against
    tests/__snapshots__/<name>.json and fails on drift.

    Kahlua has no file I/O, so the compare/store half lives host-side — this
    module only produces the canonical JSON. The display list is already
    deterministic (sorted keys, %.4g floats, monotonic z, no clocks/RNG), so
    the emitted block IS the snapshot. If a future scene introduces a volatile
    field, strip it here before emit.

    Usage in a test file:
        local Snapshot = require "UIView/Snapshot"
        Snapshot.capture("palette", Palette.build(""), 1280, 800)
]]

local Render = require "UIView/Render"

local Snapshot = {}

--- Emit a named snapshot frame (same wire format the viewer consumes).
function Snapshot.capture(name, root, width, height)
    return Render.emit(root, width, height, name)
end

return Snapshot
