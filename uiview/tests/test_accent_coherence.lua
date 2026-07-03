--[[
    Cross-mod accent coherence — one item-type colour vocabulary
    ============================================================
    An item's tooltip accent (SauceTooltips' theme -> TooltipLib's accent
    channel -> SIR's dressed tooltip rail) must match its inventory row
    stripe (SIR's sir_theme T.color.cat). Both mods keep their own copy
    (standalone doctrine: neither requires the other), so this test is the
    weld: it loads BOTH palettes and asserts the overlapping classes carry
    identical values. Change them TOGETHER.
]]

local Assert = PZTestKit.Assert

require "UIView/UIMock"
if isClient == nil then function isClient() return false end end
if isServer == nil then function isServer() return false end end

local T = require "sir_theme"
require "TooltipLib/Core"
require "TooltipLib/Filters"
require "SauceTooltips/Theme"

local tests = {}

tests["tooltip_accents_match_inventory_stripes"] = function()
    local st = _G.SauceTooltips and _G.SauceTooltips.themeItemColors
    local ok = Assert.notNil(st, "SauceTooltips exports its item palette")
    if not st then return false end
    local sir = T.color.cat
    for _, cls in ipairs({ "weapon", "food", "clothing", "literature",
                           "drainable", "container", "key", "medical" }) do
        local a, b = sir[cls], st[cls]
        ok = Assert.notNil(b, "SauceTooltips carries '" .. cls .. "'") and ok
        if a and b then
            for i = 1, 3 do
                ok = Assert.nearEqual(b[i], a[i], 0.001,
                    cls .. " channel " .. i .. " matches SIR's stripe") and ok
            end
        end
    end
    return ok
end

tests["folded_variants_match_their_parents"] = function()
    local st = _G.SauceTooltips and _G.SauceTooltips.themeItemColors
    if not st then return false end
    local ok = true
    for i = 1, 3 do
        ok = Assert.nearEqual(st._melee[i], st.weapon[i], 0.001,
            "melee folds into the one weapon red") and ok
        ok = Assert.nearEqual(st._fluid[i], st.drainable[i], 0.001,
            "fluid folds into the drainable amber") and ok
    end
    return ok
end

return tests
