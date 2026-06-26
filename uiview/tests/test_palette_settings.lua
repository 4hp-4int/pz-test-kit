--[[
    UIView — pal_settings + theme variants (Mod Options)
    ====================================================
    pal_settings resolves the size/location descriptors from the option combos and
    applies the chosen theme. PZAPI is absent in the harness, so registration is a
    no-op and apply() returns the Normal/Upper defaults. We also drive applyTheme
    directly to prove a variant mutates the skin tokens in place (live refs update)
    and that switching back restores the authored Diner Ticket values.
]]

local Assert = PZTestKit.Assert
local T  = require "palette/pal_theme"
local SP = require "palette/pal_settings"
local S  = SP.Settings

local tests = {}

tests["apply_returns_defaults_headless"] = function()
    local size, loc = S.apply()
    if not Assert.notNil(size, "a size descriptor is returned") then return false end
    if not Assert.equal(size.rowCap, 14, "default size = Normal (14-row cap)") then return false end
    return Assert.equal(loc.id, "upper", "default location = Upper")
end

tests["register_is_safe_without_pzapi"] = function()
    _G.PZAPI = nil
    local ok = pcall(S.register)
    return Assert.isTrue(ok and S._opt == nil, "register() is a no-op (no crash) when PZAPI is absent")
end

tests["theme_variant_mutates_in_place"] = function()
    local textRef = T.color.text            -- capture the live array ref
    T.applyTheme("midnight")
    -- midnight text is light; the SAME array object is updated (cached refs stay valid)
    if not Assert.equal(T.color.text, textRef, "the text token array identity is preserved") then return false end
    return Assert.isTrue(textRef[1] > 0.5, "midnight makes text light (ink-on-dark)")
end

tests["theme_default_restores_diner"] = function()
    T.applyTheme("midnight")
    T.applyTheme(nil)                        -- back to Diner Ticket
    -- the authored default panelBg is cream (high R, lower B)
    local bg = T.color.panelBg
    return Assert.isTrue(bg[1] > 0.85 and bg[3] < bg[1], "default restores the cream ticket panel")
end

tests["paper_variant_is_light_panel"] = function()
    T.applyTheme("paper")
    local bg = T.color.panelBg
    local ok = bg[1] > 0.85 and bg[2] > 0.85 and bg[3] > 0.85
    T.applyTheme(nil)                        -- leave the default applied for other tests
    return Assert.isTrue(ok, "paper is a light grey panel")
end

tests["unknown_theme_is_default"] = function()
    T.applyTheme("does-not-exist")
    local bg = T.color.panelBg
    return Assert.isTrue(bg[1] > 0.85 and bg[3] < bg[1], "an unknown theme name falls back to the default skin")
end

return tests
