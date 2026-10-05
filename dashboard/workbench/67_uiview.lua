--[[
    uiview in the workbench: TooltipLib's REAL world-object tooltip for a real
    map object, drawn through pz-test-kit/uiview's recording UI layer and
    replayed as pixels in the browser (uiview/replay.js).

    Tool:   worldTooltip{ref, sources, modules}
            sources: uiview's Lua (Recorder, FontMetrics, TextureSizes, UIMock,
                     Render), supplied by the server -- they live in the kit's
                     uiview/ tree, outside this VM's require path
            modules: TooltipLib/HookWorldObject + the mod's provider files

    The object surface is pure Lua end to end (HookWorldObject polls
    UIManager.getLastPicked on OnPreUIDraw; WorldObjectPanel is an ISPanel),
    so with UIMock standing in for ISPanel/UIManager the library runs its own
    pipeline -- entries, widths, draw -- and Render.frame records the draws.
    The item surface is different: vanilla draws item tooltips in Java
    (InventoryItem.DoTooltip into a Java ObjectTooltip), which is why item
    cards show TooltipLib's recorded content (66_tooltip.lua) instead.

    UIMock replaces UI globals (UIManager, getCore, ISPanel...) for the rest
    of this VM's life; it is loaded only when a world tooltip is asked for.
]]

local U = WB.uiview or {}
WB.uiview = U

local function loadUiview(sources)
    if U.loaded then return end
    for _, f in ipairs(sources or {}) do
        if _pz_package_loaded[f.name] == nil then
            local chunk, err = (_pz_compile or loadstring)(f.src, f.name)
            if not chunk then error("uiview " .. f.name .. ": " .. tostring(err), 0) end
            local ok, res = pcall(chunk)
            if not ok then error("uiview " .. f.name .. ": " .. tostring(res), 0) end
            _pz_package_loaded[f.name] = res == nil and true or res
        end
    end
    -- TooltipLib's WorldObjectPanel is a local in HookWorldObject; it
    -- registers through ISUIElement:addToUIManager (UIMock's). Keep that
    -- instance by Type, rather than "the last element added".
    if ISUIElement and ISUIElement.addToUIManager and not U.wrapped then
        U.wrapped = true
        local base = ISUIElement.addToUIManager
        ISUIElement.addToUIManager = function(self, ...)
            if self.Type == "TooltipLib_WorldObjectPanel" then U.panel = self end
            return base(self, ...)
        end
    end
    U.loaded = true
end

WB.register("worldTooltip", function(a)
    local o = WB.deref(a.ref)
    if not o then error("object $" .. tostring(a.ref) .. " is gone (VM restarted?) - reload the square") end
    loadUiview(a.sources)
    if WB.tooltip and WB.tooltip.strings then WB.tooltip.strings(a.strings) end
    if WB.tooltip and WB.tooltip.vanilla then WB.tooltip.vanilla() end
    local saved = { isClient, isServer, getPlayer, getSpecificPlayer }
    -- Providers gate on the local player (range, line of sight): stand the
    -- workbench player on the object's square, as you would to hover it.
    local prevS = PZEngine.setServer(true)
    local okp, player = pcall(function() return WB.standOn(o:getSquare()) end)
    PZEngine.setServer(prevS)
    if okp and player then
        getPlayer = function() return player end
        getSpecificPlayer = function() return player end
    end
    -- TooltipLib takes its MP branch only when isClient() and not isServer():
    -- render the SP path, reading the object directly (as uiview's scenes do).
    isClient = function() return false end
    isServer = function() return false end
    local ok, res = pcall(function()
        if not (WB.tooltip and WB.tooltip.ensure and WB.tooltip.ensure(a.modules)) then
            return { unavailable = "TooltipLib is not loaded in this mod's context" }
        end
        local n = TooltipLib.getProviderCount and TooltipLib.getProviderCount("object") or nil
        -- Addons get a say before the render (e.g. SauceTooltips drops its
        -- line-of-sight gate: isCouldSee comes from the client's lighting
        -- pass, which a headless VM never runs).
        for _, id in ipairs(WB.addonOrder or {}) do
            local ad = WB.addons[id]
            if ad and not ad.disabled and ad.beforeWorldTooltip then pcall(ad.beforeWorldTooltip, o) end
        end
        UIManager.getLastPicked = function() return o end
        triggerEvent("OnPreUIDraw")
        local panel = U.panel
        if not panel then return { providers = n, empty = "TooltipLib built no world-object panel (its hook did not install?)" } end
        if panel.isVisible and not panel:isVisible() then return { providers = n, empty = "no object provider claims this object" } end
        panel:setX(4); panel:setY(4)
        local w, h = math.floor(panel:getWidth() + 8), math.floor(panel:getHeight() + 8)
        local Render = require "UIView/Render"
        return { providers = n, width = w, height = h, frame = Render.capture(panel, w, h) }
    end)
    isClient, isServer, getPlayer, getSpecificPlayer = saved[1], saved[2], saved[3], saved[4]
    if not ok then error(res, 0) end
    return res
end)
