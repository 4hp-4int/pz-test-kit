--[[
    SSO — pack-manifest drift lock
    ==============================
    Same contract as test_sir_packmanifest: every name pal_chrome (and the
    two glyph consumers, pal_ui's pin star + pal_vehicle's icon) can request
    must exist in the GENERATED manifest (palette/pal_packmanifest.lua,
    written by promo/chrome_foundry.py from the actual SSOChrome.pack).
]]

local Assert = PZTestKit.Assert

require "UIView/UIMock"

local manifest = require "palette/pal_packmanifest"

local tests = {}

local function missing(names)
    local out = {}
    for _, n in ipairs(names) do
        if not manifest.names[n] then out[#out + 1] = n end
    end
    return out
end

tests["manifest_generated_and_populated"] = function()
    local ok = Assert.notNil(manifest and manifest.names, "manifest module loads")
    local n = 0
    for _ in pairs(manifest.names) do n = n + 1 end
    ok = Assert.greater(n, 80, "manifest carries the chrome names") and ok
    return ok
end

tests["chrome_nine_families_all_skins_packed"] = function()
    -- mirrors pal_chrome's TINTABLE/SKINNED x SUFFIX x KEYS9
    local KEYS9 = { "tl", "t", "tr", "l", "r", "bl", "b", "br", "c" }
    local SUFFIX = { "", "_mid", "_pap", "_forge", "_radio" }
    local names = {}
    for _, base in ipairs({ "wash", "chip" }) do
        for _, k in ipairs(KEYS9) do
            names[#names + 1] = "sso_" .. base .. "_" .. k
        end
    end
    for _, base in ipairs({ "ticket", "entry" }) do
        for _, sfx in ipairs(SUFFIX) do
            for _, k in ipairs(KEYS9) do
                names[#names + 1] = "sso_" .. base .. sfx .. "_" .. k
            end
        end
    end
    local miss = missing(names)
    return Assert.equal(#miss, 0,
        "every skin's nine-patch pieces packed (missing: " .. table.concat(miss, ", ") .. ")")
end

tests["singles_and_glyphs_packed"] = function()
    local miss = missing({
        "sso_star_fill", "sso_rule_dotted",   -- pal_chrome SINGLES
        "sso_fav-star",                        -- pal_ui pin star
        "sso_vehicle",                         -- pal_vehicle(_mechanics) icon
    })
    return Assert.equal(#miss, 0,
        "singles + glyphs packed (missing: " .. table.concat(miss, ", ") .. ")")
end

return tests
