--[[
    UIView — Scene: the TooltipLib tooltip wearing SIR's kraft ledger dress
    =======================================================================
    The Tooltip scene's REAL TooltipLib pipeline (Core + HookWorldObject +
    WorldObjectPanel), with sauce-invrender's REAL panel dress registered via
    the real API (sir_ttdress -> TooltipLib.setPanelDress). The panel's
    prerender then swaps its flat box for the sir_ledger_* nine-patch —
    exactly the code path the in-game object tooltip takes.

    Returns build() -> the dressed WorldObjectPanel, and teardown() to clear
    the dress so later scenes/tests in the same VM render the flat box again.
]]

require "UIView/UIMock"

local Base = require "UIView/scenes/Tooltip"
require "sir_ttdress"   -- SIR's dress module (registers one-shot on OnGameStart)

local TooltipDress = {}

function TooltipDress.build()
    local SIR = _G.SauceInvRender
    -- Deterministic registration: the one-shot OnGameStart register may have
    -- fired (and a prior test may have cleared the dress) — set it directly
    -- from the module's own callbacks, same spec the register path uses.
    TooltipLib.setPanelDress({
        id = "SauceInvRender",
        active = SIR.TTDress.active,
        draw = SIR.TTDress.draw,
    })
    return Base.build()
end

function TooltipDress.teardown()
    TooltipLib.clearPanelDress("SauceInvRender")
end

return TooltipDress
