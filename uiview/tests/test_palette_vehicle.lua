--[[
    UIView — pal_vehicle gating (lock-aware doors + hotwire/heater/lightbar)
    ========================================================================
    Drives the REAL registered `vehicle` source collect() against a mocked
    player + Fixtures.vehicle, asserting the gating logic the headless suite
    couldn't reach before: a locked trunk blocks "Open" (unless you can unlock),
    hotwire gates on skill, and heater/lightbar appear for equipped vehicles.
]]

local Assert = PZTestKit.Assert
local Fixtures = PZTestKit.Fixtures   -- bare global isn't visible at test-load; PZTestKit is
local SP = require "palette/pal_vehicle"

-- Global stubs the collect path touches. Set at RUNTIME (inside the helpers) —
-- top-of-file _G writes don't survive the harness strip-load.
local function setupGlobals()
    _G.Perks = { Electricity = "Electricity", Mechanics = "Mechanics" }
    _G.CharacterTrait = { BURGLAR = "BURGLAR" }
    _G.SandboxVars = _G.SandboxVars or {}
    _G.SandboxVars.VehicleEasyUse = false
    _G.getServerOptions = function() return { getBoolean = function() return true end } end
    _G.ISVehiclePartMenu = _G.ISVehiclePartMenu or {}
end

local function vehicleCollect()
    for _, s in ipairs(SP.sources) do if s.id == "vehicle" then return s.collect end end
end

local function mkPlayer(o)
    o = o or {}
    local p = { _type = "IsoPlayer" }
    p.getPlayerNum = function() return 0 end
    p.getVehicle   = function() return o.vehicle end
    p.DistToProper = function(self, veh) return o.dist or 1 end
    p.getPerkLevel = function(self, perk) return (o.perks and o.perks[perk]) or 0 end
    p.hasTrait     = function(self, t) return (o.traits and o.traits[t]) or false end
    p.hasFullInventory = function() return o.fullInv or false end
    p.getInventory = function() return {
        haveThisKeyId       = function(self, id) return o.hasKey or false end,
        getFirstTagRecurse  = function(self, tag) return o.hose and {} or nil end,
        containsEvalRecurse = function(self, pred) return o.fluidCont or false end,
    } end
    return p
end

-- collect with the vehicle OUTSIDE (interact-with), returns the command list.
local function outside(vehOpts, playerOpts)
    setupGlobals()
    local veh = Fixtures.vehicle(vehOpts)
    local p = mkPlayer(playerOpts)   -- no .vehicle => outside
    _G._pz_player = p
    _G.ISVehicleMenu = { getVehicleToInteractWith = function(_) return veh end }
    return vehicleCollect()(0)
end

-- collect with the player INSIDE the vehicle.
local function inside(vehOpts, playerOpts)
    setupGlobals()
    local veh = Fixtures.vehicle(vehOpts)
    playerOpts = playerOpts or {}
    playerOpts.vehicle = veh
    local p = mkPlayer(playerOpts)
    _G._pz_player = p
    _G.ISVehicleMenu = { getVehicleToInteractWith = function(_) return nil end }
    return vehicleCollect()(0)
end

-- getText echoes the key in the harness, so labels ARE the i18n keys.
local function find(cmds, sub)
    for _, c in ipairs(cmds) do
        if tostring(c.label):find(sub, 1, true) then return c end
    end
    return nil
end

-- siphon needs these globals + a gas-tank part. Set before outside() (setupGlobals
-- preserves existing tables via `or {}`).
local function siphonGlobals()
    _G.ItemTag = _G.ItemTag or {}; _G.ItemTag.SIPHON_GAS = "SiphonGas"
    _G.Fluid = _G.Fluid or {}; _G.Fluid.Petrol = "Petrol"
    _G.ISVehiclePartMenu = _G.ISVehiclePartMenu or {}
    _G.ISVehiclePartMenu.onTakeGasoline = function() end
end

local tests = {}

-- ── siphon gas ────────────────────────────────────────────────────────────
tests["siphon_offered_when_fuelled_with_hose_and_container"] = function()
    siphonGlobals()
    local cmds = outside({ parts = { { id = "GasTank", fuel = 30 } } }, { hose = true, fluidCont = true })
    local s = find(cmds, "SiphonGas")
    if not Assert.notNil(s, "fuelled tank + hose + container -> Siphon Gas offered") then return false end
    return Assert.isTrue(s.runnable == true, "and it's runnable")
end

tests["siphon_blocked_without_hose"] = function()
    siphonGlobals()
    local cmds = outside({ parts = { { id = "GasTank", fuel = 30 } } }, { hose = false, fluidCont = true })
    local s = find(cmds, "SiphonGas")
    if not Assert.notNil(s, "still shown so you know it's possible") then return false end
    if not Assert.isTrue(s.runnable == false, "no hose -> blocked") then return false end
    return Assert.notNil(s.blockReason, "with a reason")
end

tests["siphon_blocked_without_fluid_container"] = function()
    siphonGlobals()
    local cmds = outside({ parts = { { id = "GasTank", fuel = 30 } } }, { hose = true, fluidCont = false })
    local s = find(cmds, "SiphonGas")
    return Assert.isTrue(s ~= nil and s.runnable == false, "hose but no fluid container -> blocked")
end

tests["siphon_absent_when_tank_empty"] = function()
    siphonGlobals()
    local cmds = outside({ parts = { { id = "GasTank", fuel = 0 } } }, { hose = true, fluidCont = true })
    return Assert.isNil(find(cmds, "SiphonGas"), "empty tank -> no Siphon row at all")
end

-- ── lock-aware doors ──────────────────────────────────────────────────────
tests["locked_trunk_no_key_blocks_open"] = function()
    local cmds = outside({ door = { id = "TrunkDoor", locked = true }, canUnlock = false })
    local open = find(cmds, "OpenTrunk")
    if not Assert.notNil(open, "Open Trunk row exists") then return false end
    if not Assert.isTrue(open.runnable == false, "locked + no key -> Open Trunk is blocked") then return false end
    if not Assert.notNil(open.blockReason, "blocked with a reason (locked)") then return false end
    return Assert.isNil(find(cmds, "UnlockTrunk"), "no Unlock offered when you can't unlock")
end

tests["locked_trunk_with_key_opens_and_offers_unlock"] = function()
    local cmds = outside({ door = { id = "TrunkDoor", locked = true }, canUnlock = true })
    local open = find(cmds, "OpenTrunk")
    if not Assert.notNil(open, "Open Trunk row exists") then return false end
    if not Assert.isTrue(open.runnable == true, "locked + key -> Open is runnable (auto-unlocks)") then return false end
    return Assert.notNil(find(cmds, "UnlockTrunk"), "explicit Unlock Trunk offered")
end

tests["unlocked_door_open_and_lock"] = function()
    local cmds = outside({ door = { id = "DoorFrontLeft", locked = false }, canLock = true })
    local open = find(cmds, "Open_door")
    if not Assert.notNil(open, "Open door row exists") then return false end
    if not Assert.isTrue(open.runnable == true, "unlocked -> Open is runnable") then return false end
    if not Assert.isNil(open.blockReason, "unlocked -> no block reason") then return false end
    return Assert.notNil(find(cmds, "LockDoor"), "Lock offered when you can lock")
end

tests["open_trunk_offers_close"] = function()
    local cmds = outside({ door = { id = "TrunkDoor", open = true } })
    return Assert.notNil(find(cmds, "CloseTrunk"), "an open trunk offers Close")
end

-- ── hotwire ───────────────────────────────────────────────────────────────
tests["hotwire_runnable_with_skill"] = function()
    local cmds = inside({ engineWorking = true }, { hasKey = false, perks = { Electricity = 1, Mechanics = 2 } })
    local hw = find(cmds, "Hotwire")
    if not Assert.notNil(hw, "Hotwire offered when keyless") then return false end
    return Assert.isTrue(hw.runnable == true, "Electrical 1 + Mechanics 2 -> hotwire runnable")
end

tests["hotwire_blocked_without_skill"] = function()
    local cmds = inside({ engineWorking = true }, { hasKey = false, perks = { Electricity = 0, Mechanics = 0 } })
    local hw = find(cmds, "Hotwire")
    if not Assert.notNil(hw, "Hotwire still shown (discoverable)") then return false end
    if not Assert.isTrue(hw.runnable == false, "no skill -> hotwire blocked") then return false end
    return Assert.notNil(hw.blockReason, "blocked with the skill reason")
end

tests["burglar_can_hotwire"] = function()
    local cmds = inside({ engineWorking = true }, { hasKey = false, traits = { BURGLAR = true } })
    local hw = find(cmds, "Hotwire")
    return Assert.isTrue(hw ~= nil and hw.runnable == true, "Burglar trait -> hotwire runnable")
end

tests["no_hotwire_with_key"] = function()
    local cmds = inside({ engineWorking = true }, { hasKey = true })
    return Assert.isNil(find(cmds, "Hotwire"), "with a key there's no hotwire (Start Engine instead)")
end

-- ── heater / lightbar ─────────────────────────────────────────────────────
tests["heater_toggle_present"] = function()
    local cmds = inside({ heaterActive = false })
    return Assert.notNil(find(cmds, "HeaterOn"), "a vehicle with a Heater part offers Heater On")
end

tests["lightbar_present"] = function()
    local cmds = inside({ lightbar = true })
    return Assert.notNil(find(cmds, "Lightbar"), "an emergency vehicle offers the Lightbar")
end

tests["no_heater_no_lightbar_by_default"] = function()
    local cmds = inside({})
    if not Assert.isNil(find(cmds, "Heater"), "no Heater part -> no heater row") then return false end
    return Assert.isNil(find(cmds, "Lightbar"), "no lightbar -> no lightbar row")
end

return tests
