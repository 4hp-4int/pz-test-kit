--[[
    UIView — pal_text (UTF-8-safe truncation)
    =========================================
    Direct unit tests of the text-fitting util. The harness mock measures strings
    at a fixed px/char, so widths are deterministic.
]]

local Assert = PZTestKit.Assert
local SP = require "palette/pal_text"
local T = SP.Text
local TM = getTextManager()

-- width-per-char under the harness's measure mock, to size maxW in test.
local function w(str) return TM:MeasureStringX("Small", str) end

local tests = {}

tests["fits_unchanged"] = function()
    local s = "Open Box"
    return Assert.equal(T.truncate("Small", s, w(s) + 100), s, "a string that fits is returned unchanged")
end

tests["zero_width_empty"] = function()
    return Assert.equal(T.truncate("Small", "anything", 0), "", "maxW <= 0 -> empty string")
end

tests["truncates_with_ellipsis"] = function()
    local s = "A very long label that will not fit in the box"
    local out = T.truncate("Small", s, w("A very long") )
    if not Assert.isTrue(#out < #s, "long string is shortened") then return false end
    return Assert.isTrue(out:sub(-3) == "...", "ellipsis appended")
end

tests["utf8_boundary_backs_off_continuation_bytes"] = function()
    -- bytes 0x80..0xBF are UTF-8 continuation bytes; the boundary backs up off them.
    -- é = C3 A9; build via string.char to avoid escape-parsing ambiguity.
    local s = "ab" .. string.char(195, 169) .. "cd"   -- a b é(2 bytes) c d -> é is bytes 3-4
    -- cutting at index 3 would drop byte 4 (0xA9, a continuation) -> back up to 2.
    return Assert.equal(T.utf8Boundary(s, 3), 2, "index inside a multibyte glyph backs up to its start")
end

tests["utf8_boundary_keeps_clean_index"] = function()
    local s = "abcd"
    return Assert.equal(T.utf8Boundary(s, 3), 3, "an ASCII boundary is left untouched")
end

-- REGRESSION: in-game `font` is a UIFont OBJECT, not a string. The memo must never
-- concatenate it into a cache key (that crashes with "__concat not defined"). A
-- non-string font must work — it's used as an identity key, not concatenated.
tests["object_font_does_not_crash_memo"] = function()
    local objFont = { _uifont = "Small" }     -- stand-in for UIFont.Small (a non-string)
    local ok, out = pcall(T.truncate, objFont, "Gardening", 313.6)
    if not Assert.isTrue(ok, "truncate must not error on an object font (no concat)") then return false end
    -- and a second call hits the memo cleanly
    local ok2 = pcall(T.truncate, objFont, "Gardening", 313.6)
    return Assert.isTrue(ok2 and out ~= nil, "memo lookup with an object font works")
end

return tests
