--[[
    SIR — pack-manifest drift lock
    ==============================
    Headless getTexture never says no, so a chrome/icon name the shipped pack
    lacks only surfaces in-game as a silently-flat surface. This walks every
    name SIR's resolvers can request — sir_chrome's nine-patch families,
    sir_window/sir_render's explicit pieces, and every icon sir_icons
    registered (I._names) — against the GENERATED pack manifest
    (sir_packmanifest.lua, written by promo/chrome_foundry.py from the actual
    SIRChrome.pack + SIRIcons.pack contents).
]]

local Assert = PZTestKit.Assert

require "UIView/UIMock"
require "sir_icons"
require "sir_chrome"

local SIR = _G.SauceInvRender
local manifest = require "sir_packmanifest"

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
    ok = Assert.greater(n, 100, "manifest carries the chrome + icon names") and ok
    return ok
end

tests["chrome_nine_families_all_packed"] = function()
    -- mirrors sir_chrome's TINTABLE/UNSKINNED/SKINNED x SUFFIX x KEYS9
    local KEYS9 = { "tl", "t", "tr", "l", "r", "bl", "b", "br", "c" }
    local bases = { "wash", "chip", "entry", "wincap", "winfoot",
                    "ledger", "ledger_crm", "ledghead", "ledghead_crm" }
    local names = {}
    for _, base in ipairs(bases) do
        for _, k in ipairs(KEYS9) do
            names[#names + 1] = "sir_" .. base .. "_" .. k
        end
    end
    local miss = missing(names)
    return Assert.equal(#miss, 0,
        "every nine-patch piece packed (missing: " .. table.concat(miss, ", ") .. ")")
end

tests["explicit_window_render_pieces_packed"] = function()
    local miss = missing({
        "sir_blank", "sir_rowbevel",
        "sir_vthumb_t", "sir_vthumb_m", "sir_vthumb_b",
    })
    return Assert.equal(#miss, 0,
        "window/render singles packed (missing: " .. table.concat(miss, ", ") .. ")")
end

tests["every_registered_icon_packed"] = function()
    local I = SIR.Icons
    local ok = Assert.greater(#(I._names or {}), 50, "sir_icons recorded its names")
    local miss = missing(I._names or {})
    ok = Assert.equal(#miss, 0,
        "every icon name packed (missing: " .. table.concat(miss, ", ") .. ")") and ok
    return ok
end

return tests
