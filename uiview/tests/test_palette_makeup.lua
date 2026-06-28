--[[
    UIView — pal_makeup (apply a colour directly, skip the panel)
    =============================================================
    Drives the real `makeup` source collect() with a stubbed MakeUpDefinitions +
    a make-up item. Asserts colours are enumerated by the item's MakeUpType, gated
    on a mirror (greyed "need a mirror" without one), and the panel is the lower
    option.
]]

local Assert = PZTestKit.Assert
local SP = require "palette/pal_makeup"

local function makeupCollect()
    for _, s in ipairs(SP.sources) do if s.id == "makeup" then return s.collect end end
end

local function list(items)
    return { size = function() return #items end, get = function(_, i) return items[i + 1] end }
end

local function makeupItem(ft, mtype)
    local it = { _type = "InventoryItem" }
    it.getMakeUpType = function(self) return mtype end
    it.getName       = function(self) return (ft:match("%.(.+)$")) or ft end
    it.getFullType   = function(self) return ft end
    it.getTexture    = function(self) return nil end
    return it
end

-- collect with the given make-up item present and a mirror (or not).
local function collect(item, hasMirror)
    _G.ISApplyMakeUp = _G.ISApplyMakeUp or {}
    _G.ISTimedActionQueue = _G.ISTimedActionQueue or {}
    _G.MakeUpDefinitions = { makeup = {
        { name = "LipsRed",  item = "Base.MakeUp_LipsRed",  makeuptypes = { Lips = true, All = true } },
        { name = "LipsBlue", item = "Base.MakeUp_LipsBlue", makeuptypes = { Lips = true, All = true } },
        { name = "EyesCrow", item = "Base.MakeUp_EyesCrow", makeuptypes = { Eyes = true, All = true } },
    } }
    local inv = {
        contains = function(self, t) return t == "Mirror" and hasMirror or false end,
        getItems = function(self) return list({ item }) end,
    }
    local p = { _type = "IsoPlayer" }
    p.getInventory     = function() return inv end
    p.getVehicle       = function() return nil end
    p.getCurrentSquare = function() return nil end   -- nearMirror short-circuits on the Mirror item
    _G._pz_player = p
    return makeupCollect()(0)
end

local function find(cmds, sub)
    for _, c in ipairs(cmds) do
        if tostring(c.label):find(sub, 1, true) then return c end
    end
    return nil
end

local tests = {}

tests["lipstick_enumerates_lip_colours"] = function()
    local cmds = collect(makeupItem("Base.Lipstick", "Lips"), true)
    if not Assert.notNil(find(cmds, "LipsRed"), "lip colour Red enumerated") then return false end
    if not Assert.notNil(find(cmds, "LipsBlue"), "lip colour Blue enumerated") then return false end
    return Assert.isNil(find(cmds, "EyesCrow"), "an Eyes colour is NOT offered for a Lips item")
end

tests["colours_runnable_at_mirror"] = function()
    local cmds = collect(makeupItem("Base.Lipstick", "Lips"), true)
    local red = find(cmds, "LipsRed")
    return Assert.isTrue(red ~= nil and red.runnable == true, "at a mirror -> colour is runnable")
end

tests["colours_blocked_without_mirror"] = function()
    local cmds = collect(makeupItem("Base.Lipstick", "Lips"), false)
    local red = find(cmds, "LipsRed")
    if not Assert.isTrue(red ~= nil and red.runnable == false, "no mirror -> colour blocked") then return false end
    return Assert.notNil(red.blockReason, "blocked with a 'need a mirror' reason")
end

tests["panel_option_present_and_lower"] = function()
    local cmds = collect(makeupItem("Base.Lipstick", "Lips"), true)
    local panel = find(cmds, "panel")
    if not Assert.notNil(panel, "the make-up panel is still offered") then return false end
    return Assert.isTrue(panel.mkTier == 1, "panel is the lower-tier option (colours lead)")
end

tests["all_palette_offers_every_type"] = function()
    -- an item with MakeUpType "All" can apply every colour.
    local cmds = collect(makeupItem("Base.MakeupPalette", "All"), true)
    if not Assert.notNil(find(cmds, "LipsRed"), "All palette -> lip colour") then return false end
    return Assert.notNil(find(cmds, "EyesCrow"), "All palette -> eye colour")
end

tests["makeup_rows_are_makeup_kind"] = function()
    local cmds = collect(makeupItem("Base.Lipstick", "Lips"), true)
    return Assert.equal(find(cmds, "LipsRed").kind, "makeup", "rows carry kind=makeup (the family)")
end

return tests
