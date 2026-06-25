--[[
    UIView — pal_tvradio remote reach (couch control)
    ==================================================
    Unit-tests the two exposed gates that decide whether a far TV joins the device
    family: handHasRemote (cheap "is a TV remote in hand" pre-check, mirrors the item
    half of DeviceData.canPlayerRemoteInteract) and canRemote (the vanilla truth —
    delegates to device:getDeviceData():canPlayerRemoteInteract). Everything is
    pcall-guarded so it degrades to false when the radio API / ItemTag is absent.
]]

local Assert = PZTestKit.Assert
local SP = require "palette/pal_tvradio"
local TV = SP.TvRadio

-- a fake hand item that answers hasTag(ItemTag.TVREMOTE)
local function item(isRemote)
    return { hasTag = function(_, tag) return isRemote and tag == _G.ItemTag.TVREMOTE end }
end

-- a fake player with optional primary/secondary hand items
local function player(prim, sec)
    return {
        getPrimaryHandItem   = function() return prim end,
        getSecondaryHandItem = function() return sec end,
    }
end

-- a fake TV whose getDeviceData():canPlayerRemoteInteract returns `reach`
local function tv(reach)
    local dd = { canPlayerRemoteInteract = function() return reach end }
    return { getDeviceData = function() return dd end }
end

local tests = {}

-- handHasRemote -------------------------------------------------------------

tests["no_itemtag_means_no_remote"] = function()
    _G.ItemTag = nil
    return Assert.isTrue(TV.handHasRemote(player(item(true))) == false,
        "without the ItemTag enum (headless) the pre-check is false, never wide-scans")
end

tests["remote_in_primary_hand_detected"] = function()
    _G.ItemTag = { TVREMOTE = "TVRemote" }
    return Assert.isTrue(TV.handHasRemote(player(item(true))) == true, "TV remote in primary hand -> true")
end

tests["remote_in_secondary_hand_detected"] = function()
    _G.ItemTag = { TVREMOTE = "TVRemote" }
    return Assert.isTrue(TV.handHasRemote(player(nil, item(true))) == true, "TV remote in secondary hand -> true")
end

tests["non_remote_item_is_not_a_remote"] = function()
    _G.ItemTag = { TVREMOTE = "TVRemote" }
    return Assert.isTrue(TV.handHasRemote(player(item(false), item(false))) == false,
        "holding a non-remote item -> false")
end

tests["empty_hands_no_remote"] = function()
    _G.ItemTag = { TVREMOTE = "TVRemote" }
    return Assert.isTrue(TV.handHasRemote(player(nil, nil)) == false, "empty hands -> false")
end

-- canRemote (vanilla truth) -------------------------------------------------

tests["canRemote_true_when_device_says_so"] = function()
    return Assert.isTrue(TV.canRemote(tv(true), player()) == true,
        "device:canPlayerRemoteInteract true -> included")
end

tests["canRemote_false_when_device_refuses"] = function()
    return Assert.isTrue(TV.canRemote(tv(false), player()) == false,
        "device:canPlayerRemoteInteract false (no LOS / no remote) -> excluded")
end

tests["canRemote_false_on_bad_device"] = function()
    return Assert.isTrue(TV.canRemote({ getDeviceData = function() return nil end }, player()) == false,
        "a device with no device-data is safely excluded (pcall guard)")
end

return tests
