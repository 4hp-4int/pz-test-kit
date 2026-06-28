--[[
    UIView — Scene: a REAL TooltipLib tooltip
    =========================================
    Loads PZ-TooltipLib's actual Core + Helpers + HookWorldObject, registers a
    fixture object provider, then fires the REAL OnGameStart / OnPreUIDraw
    pipeline so TooltipLib builds and lays out the tooltip exactly as it does
    in game (DirectRenderCMT context -> WorldObjectPanel entries -> measureWidth
    -> prerender). We just capture the panel and render it into the display list.

    Nothing here reimplements TooltipLib: the entry building, column alignment,
    width measurement and draw are all the library's own code.

    Returns build() -> the WorldObjectPanel (an ISPanel), positioned for preview.
]]

require "UIView/UIMock"
UIView_setScreen(1280, 800)

-- SP render path: TooltipLib only takes the MP/network branch when
-- isClient() and not isServer(). Force SP so providers read object data direct.
function isClient() return false end
function isServer() return false end

require "TooltipLib/Core"
require "TooltipLib/Helpers"
require "TooltipLib/HookWorldObject"

local Tooltip = {}

local PROVIDER_REGISTERED = false

-- A representative world-object provider, written exactly like a SauceTooltips
-- one: it uses the ctx add* API (which routes through TooltipLib's real
-- DirectRenderCMT into the WorldObjectPanel).
local function registerDemoProvider()
    if PROVIDER_REGISTERED then return end
    PROVIDER_REGISTERED = true
    local C = TooltipLib.Colors
    TooltipLib.registerProvider({
        id = "UIView_DemoGenerator",
        target = "object",
        enabled = function(object, square) return true end,
        callback = function(ctx)
            ctx._panel:setTitle("Portable Generator", C and C.GOLD or { 0.95, 0.85, 0.4, 1 })
            ctx._panel.accentColor = { 0.96, 0.62, 0.24, 1 }
            ctx:addKeyValue("Status", "Running", C and C.GRAY, C and C.GREEN)
            ctx:addProgress("Fuel", 0.62)
            ctx:addProgress("Condition", 0.81)
            ctx:addKeyValue("Power range", "5 tiles", C and C.GRAY, C and C.WHITE)
            ctx:addDivider()
            ctx:addHeader("Connected")
            ctx:addLabel("3 appliances drawing power")
            ctx:addText("Refuel with gas before the tank runs dry to avoid a cold restart.")
        end,
        description = "UIView demo generator tooltip",
        minWidth = 220,
    })
end

-- Fixture IsoObject + square the real pipeline reads through getLastPicked.
local function fixtureObject()
    local sq = {
        getX = function() return 10 end,
        getY = function() return 12 end,
        getZ = function() return 0 end,
        getObjects = function() return { size = function() return 0 end } end,
    }
    return {
        getName = function() return "Generator" end,
        getSquare = function() return sq end,
        getObjectIndex = function() return 1 end,
        getModData = function() return {} end,
        getX = function() return 10 end,
        getY = function() return 12 end,
        getZ = function() return 0 end,
    }
end

function Tooltip.build()
    registerDemoProvider()

    -- Drive the library's real install + per-frame pipeline.
    UIManager.getLastPicked = function() return fixtureObject() end
    triggerEvent("OnGameStart")     -- installs hook, creates + registers the panel
    triggerEvent("OnPreUIDraw")     -- builds entries, measures width, sets visible

    local panel = _G.UIView_lastAddedUI
    if not panel then error("TooltipLib WorldObjectPanel was not captured") end

    -- Reposition for a clean preview (the pipeline placed it at the mock cursor).
    panel:setX(24)
    panel:setY(24)
    panel:setVisible(true)
    return panel
end

return Tooltip
