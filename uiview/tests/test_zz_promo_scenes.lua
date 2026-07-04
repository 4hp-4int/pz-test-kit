--[[
    UIView — PROMO scenes (marketing shots, not behavior fixtures)
    ==============================================================
    Scenes whose CONTENT is curated for Workshop/promo captures — coherent
    items instead of row-kind exercise fixtures (a frying pan that attracts
    rats is great coverage and nonsense marketing). Kept in a zz_ file so
    these emits run LAST: the harness element-id counter is global per run,
    and emitting mid-suite would shift every later golden's el ids.

    tooltippromo: the dressed bait card (Cabbage — ATTRACTS is true).
]]

local Assert = PZTestKit.Assert
local Render = require "UIView/Render"
local TooltipDressItem = require "UIView/scenes/TooltipDressItem"

-- The scene drives TTDress.draw DIRECTLY (no TooltipLib hook), so nothing
-- calls C.active() -> C.resolve() for us — unresolved chrome makes every
-- nine a silent no-op and the card renders bare. Prime it explicitly.
_G.SauceInvRender.Chrome.resolve()

do
    -- food green on the accent channel (cabbage), full ruled treatment
    local card = TooltipDressItem.buildPromo({ 0.40, 0.85, 0.35, 1.0 })
    Render.emit(card, card:getWidth() + 48, card:getHeight() + 48, "tooltippromo")
end

do
    -- the UNDRESSED generator card, drawn with ONLY the rows the real
    -- SauceTooltips_Generator provider emits (ObjectProviders.lua): name
    -- header, Running/Connected labels, Fuel + Condition bars. An earlier
    -- promo shot invented rows ("power range", appliance counts) — promo
    -- cards claim exactly what ships.
    local GenCard = ISPanel:derive("STGeneratorPromoCard")
    function GenCard:render()
        local w, h = self.width, self.height
        self:drawRect(0, 0, w, h, 0.82, 0.02, 0.02, 0.02)          -- vanilla box
        self:drawRectBorder(0, 0, w, h, 1, 0.4, 0.4, 0.4)
        self:drawRect(0, 0, 3, h, 1, 0.25, 0.75, 0.30)             -- status accent (running)
        self:drawText("Portable Generator", 12, 8, 1, 0.95, 0.55, 1, UIFont.Medium)
        self:drawText("Running",   12, 40, 0.3, 0.9, 0.35, 1, UIFont.Small)
        self:drawText("Connected", 12, 62, 0.9, 0.85, 0.3, 1, UIFont.Small)
        self:drawText("Fuel",      12, 90, 0.85, 0.85, 0.85, 1, UIFont.Small)
        self:drawRect(110, 94, 150, 8, 1, 0.10, 0.10, 0.10)
        self:drawRect(110, 94, 93, 8, 1, 0.25, 0.75, 0.30)
        self:drawText("62%", 268, 90, 1, 1, 1, 1, UIFont.Small)
        self:drawText("Condition", 12, 114, 0.85, 0.85, 0.85, 1, UIFont.Small)
        self:drawRect(110, 118, 150, 8, 1, 0.10, 0.10, 0.10)
        self:drawRect(110, 118, 121, 8, 1, 0.25, 0.75, 0.30)
        self:drawText("81%", 268, 114, 1, 1, 1, 1, UIFont.Small)
    end
    local card = ISPanel.new(GenCard, 24, 24, 300, 148)
    card:setBackgroundColor(0, 0, 0, 0)
    card:setBorderColor(0, 0, 0, 0)
    Render.emit(card, card:getWidth() + 48, card:getHeight() + 48, "tooltippromogen")
end

local tests = {}

tests["promo_card_emits"] = function()
    local card = TooltipDressItem.buildPromo({ 0.40, 0.85, 0.35, 1.0 })
    Render.frame(card, card:getWidth() + 48, card:getHeight() + 48)
    return Assert.notNil(card.ink, "promo ink attached")
        and Assert.equal(card.ink.name, "Cabbage", "coherent promo subject")
end

return tests
