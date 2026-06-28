--[[
    SaucePalette i18n helper — fallback + substitution
    ==================================================
    The palette's chrome is localized via getText with an English fallback, so it
    renders correctly in-game (JSON translations) AND in this headless harness
    (whose getText stub echoes the key -> fallback path). Guards both behaviours.
]]

local Assert = PZTestKit.Assert
local SP = require "palette/pal_i18n"

local tests = {}

tests["L_falls_back_to_english"] = function()
    -- harness getText echoes the key, so L must return the fallback
    return Assert.equal(SP.L("IGUI_SaucePal_Search", "Search actions..."), "Search actions...",
        "unresolved key falls back to English")
end

tests["L_handles_missing_fallback"] = function()
    return Assert.equal(SP.L("IGUI_SaucePal_Nope"), "IGUI_SaucePal_Nope",
        "no fallback -> the key itself (never nil)")
end

tests["Lf_substitutes_placeholders"] = function()
    if not Assert.equal(SP.Lf("IGUI_SaucePal_LoadGun", "Load %1", "M16"), "Load M16", "single %1") then return false end
    return Assert.equal(SP.Lf("IGUI_SaucePal_RoundsReady", "%1 / %2 rounds ready", 30, 60),
        "30 / 60 rounds ready", "multiple placeholders")
end

tests["Lf_handles_PZ_positional_form"] = function()
    -- PZ B42 normalizes "%1" -> Java positional "%1$s" when it loads the JSON, so
    -- in-game getText returns "%1$s actions". Lf must substitute it cleanly rather
    -- than leak the orphaned "$s" ("3$s actions" was the live bug).
    local orig = getText
    _G.getText = function(k)
        if k == "TEST_PZ_POS" then return "%1$s actions" end
        return orig and orig(k) or k
    end
    local out = SP.Lf("TEST_PZ_POS", "%1 actions", 3)
    _G.getText = orig
    return Assert.equal(out, "3 actions", "%1$s positional form substituted, no orphan $s")
end

tests["catLabel_and_reasonLabel"] = function()
    if not Assert.equal(SP.catLabel("med", "MED"), "MED", "category label falls back") then return false end
    if not Assert.equal(SP.reasonLabel("deep wound"), "deep wound", "reason word falls back (spaces ok)") then return false end
    return Assert.equal(SP.reasonLabel(nil), nil, "nil reason stays nil")
end

return tests
