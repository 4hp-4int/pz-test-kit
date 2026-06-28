--[[
    UIView — pal_vehicle_mechanics gating
    =====================================
    Drives the real `vehmech` source collect() with a parts-equipped
    Fixtures.vehicle, asserting per-part actions appear under the right
    conditions: install (empty slot + have the item + canInstall), uninstall
    (occupied + canUninstall), gas add/siphon, and window open/close/smash.
]]

local Assert = PZTestKit.Assert
local Fixtures = PZTestKit.Fixtures
local SP = require "palette/pal_vehicle_mechanics"

local function setupGlobals(invHasType)
    _G.ISVehiclePartMenu = {
        getGasCanNotEmpty = function(p, part) return _G._gasCanNotEmpty end,
        getGasCanNotFull  = function(p, part) return _G._gasCanNotFull end,
    }
    _G.ISVehicleMenu = { getVehicleToInteractWith = function(_) return nil end,
                         getVehicleDisplayName = function(_) return "Truck" end }
end

local function mkPlayer(veh, invTypes)
    local p = { _type = "IsoPlayer" }
    p.getPlayerNum = function() return 0 end
    p.getVehicle   = function() return veh end
    p.DistToProper = function(self, v) return 1 end
    p.getInventory = function()
        return { getFirstTypeRecurse = function(self, t)
            return invTypes and invTypes[t] and { _type = "InventoryItem" } or nil
        end }
    end
    return p
end

local function vehmechCollect()
    for _, s in ipairs(SP.sources) do if s.id == "vehmech" then return s.collect end end
end

local function collect(parts, invTypes)
    setupGlobals()
    local veh = Fixtures.vehicle({ id = 7, parts = parts })
    _G._pz_player = mkPlayer(veh, invTypes)
    return vehmechCollect()(0)
end

local function find(cmds, sub)
    for _, c in ipairs(cmds) do
        if tostring(c.label):find(sub, 1, true) then return c end
    end
    return nil
end

local tests = {}

tests["uninstall_when_occupied_and_allowed"] = function()
    local cmds = collect({
        { id = "TireFrontLeft", category = "tire", itemType = { "Base.NormalTire" },
          installed = true, tables = { uninstall = {} }, canUninstall = true },
    })
    return Assert.notNil(find(cmds, "Uninstall"), "occupied slot + canUninstall -> Uninstall")
end

tests["no_uninstall_without_table"] = function()
    local cmds = collect({
        { id = "TireFrontLeft", itemType = { "Base.NormalTire" }, installed = true,
          tables = {}, canUninstall = true },   -- no uninstall table
    })
    return Assert.isNil(find(cmds, "Uninstall"), "no uninstall recipe -> no Uninstall")
end

tests["install_when_empty_and_have_item"] = function()
    local cmds = collect({
        { id = "Battery", category = "battery", itemType = { "Base.CarBattery1" },
          installed = false, tables = { install = {} }, canInstall = true },
    }, { ["Base.CarBattery1"] = true })   -- have the part in inventory
    return Assert.notNil(find(cmds, "Install"), "empty slot + have item + canInstall -> Install")
end

tests["no_install_without_item"] = function()
    local cmds = collect({
        { id = "Battery", itemType = { "Base.CarBattery1" }, installed = false,
          tables = { install = {} }, canInstall = true },
    }, {})   -- inventory lacks the part
    return Assert.isNil(find(cmds, "Install"), "no part in inventory -> no Install")
end

tests["gas_add_and_siphon"] = function()
    _G._gasCanNotEmpty = { _type = "InventoryItem" }   -- have a non-empty can
    _G._gasCanNotFull  = { _type = "InventoryItem" }   -- and a not-full can
    local cmds = collect({
        { id = "GasTank", category = "fuel", itemType = { "x" }, installed = true,
          tables = {}, fuel = 30 },
    })
    if not Assert.notNil(find(cmds, "Add Gasoline"), "non-empty can -> Add Gasoline") then return false end
    return Assert.notNil(find(cmds, "Siphon"), "tank has fuel + not-full can -> Siphon")
end

tests["no_siphon_when_tank_empty"] = function()
    _G._gasCanNotEmpty = nil
    _G._gasCanNotFull  = { _type = "InventoryItem" }
    local cmds = collect({
        { id = "GasTank", itemType = { "x" }, installed = true, tables = {}, fuel = 0 },
    })
    return Assert.isNil(find(cmds, "Siphon"), "empty tank -> no Siphon")
end

tests["window_open_and_smash"] = function()
    local cmds = collect({
        { id = "WindowFrontLeft", category = "window", itemType = { "x" }, installed = true,
          tables = {}, window = { openable = true, destroyed = false, open = false } },
    })
    if not Assert.notNil(find(cmds, "Open Window"), "closed openable window -> Open Window") then return false end
    return Assert.notNil(find(cmds, "Smash Window"), "intact window -> Smash Window")
end

tests["nodisplay_part_skipped"] = function()
    local cmds = collect({
        { id = "Hidden", category = "nodisplay", itemType = { "x" }, installed = true,
          tables = { uninstall = {} }, canUninstall = true },
    })
    return Assert.equal(#cmds, 0, "nodisplay parts produce no actions")
end

return tests
