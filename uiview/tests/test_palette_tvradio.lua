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

-- collect / deviceActions: the emitted interaction set per device --------------

-- a DeviceData stub; opts override the state getters (false/0 are respected).
local function dd(opts)
    opts = opts or {}
    local function g(k, d) return function() if opts[k] == nil then return d else return opts[k] end end end
    return {
        getIsTurnedOn = g("on", false), getDeviceVolume = g("vol", 0), getIsTelevision = g("tv", false),
        getIsBatteryPowered = g("battery", true), getPower = g("power", 100), canBePoweredHere = g("here", false),
        hasMedia = g("media", false), isPlayingMedia = g("playing", false),
        getName = function() return "Hand Radio" end, canPlayerRemoteInteract = function() return false end,
    }
end

-- install a player holding one Radio device, plus the radio-system globals.
local function radioEnv(deviceData, fn)
    local names = { "getSpecificPlayer", "ISRadioAction", "ISTimedActionQueue", "instanceof" }
    local saved = {}; for _, n in ipairs(names) do saved[n] = _G[n] end
    local radio = { _type = "Radio", getName = function() return "Hand Radio" end,
        getTexture = function() return nil end, getDeviceData = function() return deviceData end }
    local container = { getItems = function() return { size = function() return 1 end, get = function() return radio end } end }
    local p = { getInventory = function() return container end, getCurrentSquare = function() return nil end }
    _G.getSpecificPlayer = function() return p end
    _G.ISRadioAction = { new = function() return {} end }
    _G.ISTimedActionQueue = { add = function() end }
    _G.instanceof = function(o, c) return type(o) == "table" and o._type == c end
    local out
    local ok, err = pcall(function() out = TV.collect(0) end)
    for _, n in ipairs(names) do _G[n] = saved[n] end
    if not ok then error(err) end
    return fn(out)
end

tests["off_device_offers_power_and_panel_only"] = function()
    return radioEnv(dd({ on = false }), function(out)
        if not Assert.equal(#out, 2, "off device: Turn On + Device panel (no volume/media)") then return false end
        if not Assert.equal(out[1].category, "device", "device category") then return false end
        return Assert.isTrue(out[1].label:find("Turn On", 1, true) ~= nil, "first action turns it on")
    end)
end

tests["on_device_offers_full_controls"] = function()
    return radioEnv(dd({ on = true, vol = 0.5 }), function(out)
        -- Turn Off, Volume Up, Volume Down, Mute, Device panel
        return Assert.equal(#out, 5, "on device: power + vol up/down + mute + panel")
    end)
end

tests["powerless_device_blocks_the_power_action"] = function()
    return radioEnv(dd({ on = false, battery = false, power = 0, here = false }), function(out)
        local turnOn
        for _, c in ipairs(out) do if c.label:find("Turn On", 1, true) then turnOn = c end end
        if not Assert.notNil(turnOn, "the power action is still listed") then return false end
        return Assert.equal(turnOn.runnable, false, "but blocked when there's no power")
    end)
end

tests["headless_without_radio_system_yields_nothing"] = function()
    local saved = { gsp = _G.getSpecificPlayer, ra = _G.ISRadioAction, tq = _G.ISTimedActionQueue }
    _G.getSpecificPlayer = function() return { getInventory = function() return nil end, getCurrentSquare = function() return nil end } end
    _G.ISRadioAction = nil   -- radio system absent (the headless case)
    _G.ISTimedActionQueue = { add = function() end }
    local out, ok = nil, nil
    ok = pcall(function() out = TV.collect(0) end)
    _G.getSpecificPlayer, _G.ISRadioAction, _G.ISTimedActionQueue = saved.gsp, saved.ra, saved.tq
    if not Assert.equal(ok, true, "collect doesn't error with no radio system") then return false end
    return Assert.equal(#out, 0, "no radio system -> no rows")
end

-- ── status detail (the tooltip-style preview) ───────────────────────────────
local function hasRow(d, text, qty)
    for _, r in ipairs(d.rows) do
        if r.text == text and (qty == nil or r.qty == qty) then return true end
    end
    return false
end

tests["device_detail_radio_frequency_volume_media"] = function()
    local f = function(v) return function() return v end end
    local deviceData = { getChannel = f(95400) }   -- 95.4 MHz
    -- name, on, vol(0.5), isTV(false), hasMedia(true), playing(true), canPower(true), dd
    local d = TV.deviceDetail("Radio", true, 0.5, false, true, true, true, deviceData)
    if not Assert.isTrue(hasRow(d, "on"), "an on device reads on") then return false end
    if not Assert.isTrue(hasRow(d, "volume", "50%"), "volume reads 50%") then return false end
    if not Assert.isTrue(hasRow(d, "frequency", "95.4 MHz"), "a radio shows frequency in MHz") then return false end
    return Assert.isTrue(hasRow(d, "playing a tape"), "playing media is shown")
end

tests["device_detail_off_no_power_no_channel"] = function()
    -- off TV, no power, no dd -> the channel row is existence-guarded away (no crash)
    local d = TV.deviceDetail("Television", false, 0, true, false, false, false, nil)
    if not Assert.isTrue(hasRow(d, "off"), "off device reads off") then return false end
    return Assert.isTrue(hasRow(d, "no power"), "powerless device flags 'no power'")
end

return tests
