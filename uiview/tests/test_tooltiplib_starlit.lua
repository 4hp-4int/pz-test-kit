--[[
    TooltipLib StarlitLibrary adapter — native content integration
    ==============================================================
    Starlit owns the item card but fires InventoryUI.onFillItemTooltip so
    other mods add rows to ITS layout (one render pass, authoritative
    height). The adapter's filler runs TooltipLib's active item providers
    with their context bound to Starlit's layout — content lands NATIVELY,
    no deferred stapling / extent inference. Locks:
      - active providers' rows are added to Starlit's layout via the ctx API
      - replacesVanilla claimers stand down (Starlit already drew vanilla)
      - the declared accent is stashed for the render path to draw
]]

local Assert = PZTestKit.Assert
require "UIView/UIMock"
require "TooltipLib/Core"
require "TooltipLib/Helpers"
require "TooltipLib/StarlitAdapter"

local fill = TooltipLib._starlitFill   -- the onFillItemTooltip listener

-- a vanilla-Layout-shaped mock: addItem() returns a LayoutItem whose
-- setLabel/setValue/setProgress record what landed (the same API Starlit's
-- own helpers and our ctx both call on the real layout)
local function makeLayout()
    local L = { rows = {} }
    function L.addItem(self)
        local it = {}
        function it.setLabel(item, txt) item.label = txt; return item end
        function it.setValue(item, v) item.value = v; return item end
        function it.setValueRight(item, v) item.value = tostring(v); return item end
        function it.setProgress(item, f) item.progress = f; return item end
        L.rows[#L.rows + 1] = it
        return it
    end
    return L
end

local function makeItem(id)
    return setmetatable({ _id = id or 1 }, {
        __index = { getID = function(self) return self._id end,
                    getName = function() return "Mock" end },
    })
end

local function clearProviders()
    for _, id in ipairs({ "SL_Info", "SL_Claim", "SL_Accent" }) do
        pcall(TooltipLib.removeProvider, id)
    end
end

local tests = {}

tests["adapter_exposes_filler"] = function()
    return Assert.isTrue(type(fill) == "function", "StarlitAdapter loaded + filler exposed")
end

tests["providers_fill_starlit_layout_natively"] = function()
    clearProviders()
    TooltipLib.registerProvider({
        id = "SL_Info", target = "item", enabled = function() return true end,
        callback = function(ctx) ctx:addKeyValue("Fuel", "62%") end,
        description = "info",
    })
    local layout = makeLayout()
    fill({}, layout, makeItem(1))
    local found = false
    for _, r in ipairs(layout.rows) do
        if tostring(r.label):find("Fuel", 1, true) then found = true end
    end
    clearProviders()
    return Assert.isTrue(found, "provider key/value landed in Starlit's layout")
end

tests["claimers_stand_down_under_starlit"] = function()
    clearProviders()
    TooltipLib.registerProvider({
        id = "SL_Claim", target = "item", replacesVanilla = true,
        enabled = function() return true end,
        callback = function(ctx) ctx:addLabel("mirrored vanilla row") end,
        description = "claimer",
    })
    local layout = makeLayout()
    fill({}, layout, makeItem(2))
    clearProviders()
    return Assert.equal(#layout.rows, 0,
        "replacesVanilla claimer adds nothing (Starlit drew vanilla already)")
end

tests["declared_accent_is_stashed_for_render"] = function()
    clearProviders()
    TooltipLib.registerProvider({
        id = "SL_Accent", target = "item", enabled = function() return true end,
        callback = function(ctx)
            ctx:setAccentColor({ 0.9, 0.3, 0.3, 1 })
            ctx:addLabel("weapon")
        end,
        description = "accent",
    })
    TooltipLib._starlitAccent = nil
    local layout = makeLayout()
    fill({}, layout, makeItem(3))
    local a = TooltipLib._starlitAccent
    clearProviders()
    return Assert.isTrue(a ~= nil and a[1] == 0.9,
        "declared accent stashed for the render path to draw")
end

tests["no_active_providers_adds_nothing"] = function()
    clearProviders()
    local layout = makeLayout()
    fill({}, layout, makeItem(4))
    return Assert.equal(#layout.rows, 0, "empty provider set = pure Starlit card")
end

return tests
