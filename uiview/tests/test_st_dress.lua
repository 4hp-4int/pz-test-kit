--[[
    SauceTooltips — standalone tooltip dress (Dress.lua)
    ====================================================
    ST ships its own kraft label card so the dressed tooltip works WITHOUT
    Sauce Inventory Rendering installed (the dress that used to require SIR).
    Locks: every resolver-constructible st_ piece exists in the generated
    STChrome manifest; the card actually paints st_ pieces through the
    ObjectTooltip-shaped shim; registration YIELDS when SIR is loaded
    (TooltipLib holds ONE dress); the mod option gates active().
]]

local Assert = PZTestKit.Assert
local Render = require "UIView/Render"
local Recorder = require "UIView/Recorder"
require "UIView/UIMock"
require "SauceTooltips/Dress"

local D = _G.SauceTooltips_Dress
local manifest = require "SauceTooltips/PackManifest"

local tests = {}

tests["every_resolver_name_packed"] = function()
    local KEYS9 = { "tl", "t", "tr", "l", "r", "bl", "b", "br", "c" }
    local miss = {}
    for _, base in ipairs({ "ledger", "wincap", "entry", "chip" }) do
        for _, k in ipairs(KEYS9) do
            local n = "st_" .. base .. "_" .. k
            if not manifest.names[n] then miss[#miss + 1] = n end
        end
    end
    return Assert.equal(#miss, 0,
        "every st_ nine piece packed (missing: " .. table.concat(miss, ", ") .. ")")
end

local function shimOver(panel)
    local t = { padTop = 5 }
    function t.getLineSpacing() return 18 end
    function t.DrawTextureScaledColor(_, tex, x, y, w, h, r, g, b, a)
        panel:drawTextureScaled(tex, x, y, w, h, a or 1, r or 1, g or 1, b or 1)
    end
    return t
end

tests["card_paints_st_pieces"] = function()
    D._tripped = false
    local Card = ISPanel:derive("STDressTestCard")
    function Card:render()
        D.draw(self, shimOver(self), self.width, self.height, "item",
            { 0.40, 0.85, 0.35, 1.0 })
    end
    local panel = ISPanel.new(Card, 0, 0, 300, 150)
    Render.frame(panel, 320, 170)
    local body, rail = false, false
    for _, o in ipairs(Recorder.ops) do
        local n = tostring(o.name or "")
        if n:find("st_ledger_", 1, true) then body = true end
        if n:find("st_chip_", 1, true) then rail = true end
    end
    return Assert.isTrue(body, "kraft ledger body painted (st_ledger_*)")
        and Assert.isTrue(rail, "accent rail painted (st_chip_*, tinted)")
end

tests["registration_yields_to_SIR"] = function()
    local hadSIR = _G.SauceInvRender
    _G.SauceInvRender = { TTDress = {} }
    D._registered = nil
    D.register()
    local yielded = Assert.isTrue(not D._registered, "no registration while SIR is loaded")
    _G.SauceInvRender = hadSIR
    return yielded
end

tests["option_gates_active"] = function()
    local O = _G.SauceTooltips_Options
    local orig = O.dressedTooltips
    O.dressedTooltips = function() return false end
    local off = Assert.isTrue(not D.active(), "dress inactive when the option is off")
    O.dressedTooltips = orig
    return off
end

return tests
