--[[
    CraftMock — headless stubs for PZ's B42 craft system.
    =====================================================
    The uiview harness has no recipe DB, so the palette's craft/rip providers
    (pal_craft, pal_rip) couldn't be unit-tested. This mocks just enough of the
    B42 craft API to drive them and RECORD what gets queued, so we can assert
    "rip all queued one action per item via the right per-fabric recipe" headlessly.

    Stubs: getSpecificPlayer, ISInventoryPaneContextMenu.getContainers,
    getScriptManager():getCraftRecipe, HandcraftLogic.new (setContainers /
    setRecipeFromContextClick / canPerformCurrentRecipe), ISHandcraftAction.FromLogic,
    ISTimedActionQueue.add, and instanceof. install() saves the originals;
    restore() puts them back (call it at the end of each test to avoid leaks).

    Usage:
      local CraftMock = require "UIView/CraftMock"
      CraftMock.install({ CraftMock.clothing("Tshirt","base:ripclothingcotton") })
      ... run provider ...
      assert(#CraftMock.queue == ...)            -- recorded {recipe=name, item=...}
      CraftMock.restore()
]]

local CraftMock = {}

-- 0-indexed Java-list-like wrapper (size()/get(i)) over a 1-indexed Lua table.
local function jlist(t)
    return { size = function() return #t end, get = function(_, i) return t[i + 1] end }
end
CraftMock.jlist = jlist

-- A Clothing item. tag e.g. "base:ripclothingcotton"; opts.fav / opts.equipped.
function CraftMock.clothing(name, tag, opts)
    opts = opts or {}
    return {
        _type      = "Clothing",
        _equipped  = opts.equipped or false,
        getDisplayName = function() return name end,
        getFullType    = function() return "Base." .. name end,
        isFavorite     = function() return opts.fav or false end,
        getTags        = function() return { toArray = function() return { tag } end } end,
    }
end

CraftMock.queue = {}   -- recorded actions: { recipe = <name>, item = <item> }
CraftMock.craftCount = 5  -- what logic:getPossibleCraftCount returns (settable per test)

-- a plain inventory item of fulltype `ft` (for craft input enumeration)
function CraftMock.item(ft)
    return { _type = "Item", getFullType = function() return ft end, getName = function() return ft end,
             getTexture = function() return nil end }
end

-- a craft recipe whose consumed inputs accept the given fulltypes (1 or more):
--   CraftMock.recipe("OpenBox", "Base.Box")              -- single input
--   CraftMock.recipe("PackAmmo", "Base.Box", "Base.Ammo") -- two inputs (Pack)
function CraftMock.recipe(name, ...)
    local fts = { ... }
    return {
        _recipe = name,
        getName = function() return name end,
        getTranslationName = function() return name end,
        isCanBeDoneFromFloor = function() return true end,
        getInputs = function()
            local inputs = {}
            for _, ft in ipairs(fts) do
                inputs[#inputs + 1] = {
                    isTool = function() return false end,
                    isAutomationOnly = function() return false end,
                    getPossibleInputItems = function()
                        return jlist({ { getFullName = function() return ft end } })
                    end,
                }
            end
            return jlist(inputs)
        end,
    }
end

local SAVED = {}
local NAMES = {
    "getSpecificPlayer", "ISInventoryPaneContextMenu", "getScriptManager",
    "HandcraftLogic", "ISHandcraftAction", "ISTimedActionQueue", "instanceof",
    "ISEntityUI", "ISCraftingUI",
}

function CraftMock.install(items)
    for _, n in ipairs(NAMES) do SAVED[n] = _G[n] end
    CraftMock.queue = {}

    local container = {
        getItems = function() return jlist(items) end,
        -- per-subject expansion (pal_craft) finds held boxes via getFirstTypeRecurse.
        getFirstTypeRecurse = function(_, ft)
            for _, it in ipairs(items) do
                if it.getFullType and it:getFullType() == ft then return it end
            end
            return nil
        end,
    }
    local player = {
        getInventory       = function() return container end,
        isEquippedClothing = function(_, it) return it._equipped or false end,
        tooDarkToRead      = function() return CraftMock.tooDark or false end,
        getPlayerNum       = function() return 0 end,
    }

    _G.getSpecificPlayer = function() return player end
    _G.ISInventoryPaneContextMenu = { getContainers = function() return jlist({ container }) end }
    _G.getScriptManager = function()
        return { getCraftRecipe = function(_, name) return { _recipe = name } end }
    end
    _G.HandcraftLogic = {
        new = function()
            return {
                setContainers = function() end,
                setIsoObject = function() end,
                findCraftSurface = function() return nil end,
                -- pin state models vanilla's manual-select mode: the context
                -- click PINS (manual), plain setRecipe is auto-select
                setRecipe = function(self, r) self._recipe = r; self._pinned = false end,
                setRecipeFromContextClick = function(self, r, it)
                    self._recipe = r; self._item = it; self._pinned = true
                end,
                getRecipeData = function() return {
                    getAllInputItems = function() return jlist({}) end,
                    getAllPutBackInputItems = function() return jlist({}) end,
                } end,
                isUsingRecipeAtHandBenefit = function() return false end,
                -- CraftMock.canCraft = false simulates "applies but you lack materials"
                -- (for pal_repair's blocked-but-discoverable path). Default: craftable.
                -- CraftMock.pinStarves = true models the MULTI-COUNT-INPUT trap
                -- (Pack Nails): manual/pinned mode fails canPerform while the
                -- auto-select path says craftable (BaseCraftingLogic passes
                -- null allItems to canPerform when isManualSelectInputs).
                canPerformCurrentRecipe = function(self)
                    if CraftMock.canCraft == false then return false end
                    if CraftMock.pinStarves and self._pinned then return false end
                    return self._recipe ~= nil
                end,
                isInputSatisfied = function() return CraftMock.canCraft ~= false end,
                getPossibleCraftCount = function() return CraftMock.craftCount end,
                isCharacterInRangeOfWorkbench = function() return true end,
                setManualSelectInputs = function(self, b) self._manual = b end,
                autoPopulateInputs = function() end,
                updateManualInputAllowedItemTypes = function() end,
                startCraftAction = function() end,
            }
        end,
    }
    _G.ISHandcraftAction = {
        FromLogic = function(logic)
            return { recipe = logic._recipe and logic._recipe._recipe, item = logic._item }
        end,
    }
    -- multi-craft: returns `qty` actions (with setOnStart/setOnComplete hooks the
    -- caller wires); adds to the queue itself only when addToQueue is true.
    _G.ISEntityUI = {
        -- single craft (craftOne): returns an action; caller wires completion
        -- and hands it to logic:startCraftAction
        HandcraftStart = function(_, logic)
            local a = {
                recipe = logic._recipe and logic._recipe._recipe or (logic._recipe and logic._recipe:getName()),
                pinned = logic._pinned,
                setOnComplete = function() end,
            }
            CraftMock.queue[#CraftMock.queue + 1] = a
            return a
        end,
        HandcraftStartMultiple = function(_, logic, _, qty, addToQueue)
            local acts = {}
            for i = 1, qty do
                local a = {
                    recipe = logic._recipe and logic._recipe._recipe, multi = true,
                    setOnStart = function() end, setOnComplete = function() end,
                }
                acts[i] = a
                if addToQueue then CraftMock.queue[#CraftMock.queue + 1] = a end
            end
            return acts
        end,
    }
    _G.ISCraftingUI = { ReturnItemsToOriginalContainer = function() end }
    _G.ISTimedActionQueue = { add = function(a) CraftMock.queue[#CraftMock.queue + 1] = a end }
    _G.instanceof = function(o, c) return type(o) == "table" and o._type == c end

    return container, player
end

function CraftMock.restore()
    for _, n in ipairs(NAMES) do _G[n] = SAVED[n] end
end

return CraftMock
