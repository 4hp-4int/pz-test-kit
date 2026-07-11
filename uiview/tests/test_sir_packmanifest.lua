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
                    "ledger", "ledger_crm", "ledghead", "ledghead_crm",
                    -- midnight (2026 grayscale glass): its own skinned set
                    -- PLUS per-look rails/entry (MIDNIGHT_ONLY in sir_chrome)
                    "ledger_mid", "ledghead_mid",
                    "entry_mid", "wincap_mid", "winfoot_mid" }
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
        "sir_vthumb_mid_t", "sir_vthumb_mid_m", "sir_vthumb_mid_b",
        -- sir_window resolves these directly (not through sir_icons' ptex)
        "sir_ui-close", "sir_ui-info", "sir_ui-pin", "sir_ui-pin-off",
        "sir_ui-expand", "sir_ui-collapse", "sir_ui-funnel",
        "sir_ui-xfer-ink", "sir_ui-xfer-multi-ink",
        -- craftdress glyph swaps (sir_craftdress TEX_SWAPS resolves directly)
        "sir_prop-walk", "sir_prop-light", "sir_prop-book",
        "sir_prop-surface", "sir_prop-clock", "sir_fav-star-off",
        "sir_ui-plus-ink", "sir_ui-minus-ink", "sir_ui-grid-ink",
        "sir_ui-list-ink", "sir_ui-prev-ink", "sir_ui-next-ink",
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
