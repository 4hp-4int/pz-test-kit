--[[ pal_pins — pinned commands (forced to the top of the zero-state). Small but
     was 38% covered. Pins persist to a flat file via getFileReader/getFileWriter and
     key off History.idOf (kind|label|source). ]]
local Assert = PZTestKit.Assert
require "palette/pal_history"   -- SP.History.idOf
require "palette/pal_pins"
local SP = _G.SaucePalette
local Pn = SP.Pins

-- No pins file on disk -> load() starts from empty. getFileWriter is already a
-- harness no-op, so save() is harmless.
local function noFile(fn)
    local saved = _G.getFileReader
    _G.getFileReader = function() return nil end
    local ok, err = pcall(fn)
    _G.getFileReader = saved
    if not ok then error(err) end
end

local tests = {}

tests["unpinned_by_default"] = function()
    local r
    noFile(function() r = Pn.isPinned({ kind = "craft", label = "Nobody Pinned This", source = "craft" }) end)
    return Assert.equal(r, false, "an un-pinned command reads unpinned")
end

tests["toggle_pins_then_unpins"] = function()
    local cmd = { kind = "craft", label = "Pin Me", source = "craft" }
    local on, mid, off
    noFile(function()
        on  = Pn.toggle(cmd)        -- pin
        mid = Pn.isPinned(cmd)
        off = Pn.toggle(cmd)        -- unpin
    end)
    if not Assert.equal(on, true, "first toggle pins") then return false end
    if not Assert.equal(mid, true, "isPinned true while pinned") then return false end
    return Assert.equal(off, false, "second toggle unpins")
end

tests["toggle_without_identity_is_noop"] = function()
    -- no stable id (idOf nil) -> can't pin; toggle must bail, not error
    local saved = SP.History.idOf
    SP.History.idOf = function() return nil end
    local r, ok
    noFile(function() ok = pcall(function() r = Pn.toggle({ label = "x" }) end) end)
    SP.History.idOf = saved
    if not Assert.equal(ok, true, "toggle without an id doesn't error") then return false end
    return Assert.isTrue(r == nil, "toggle is a no-op without a stable id")
end

return tests
