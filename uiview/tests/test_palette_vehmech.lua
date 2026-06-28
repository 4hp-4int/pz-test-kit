--[[ pal_vehicle_mechanics — the per-vehicle family. collect() needs the live
     vehicle API (no harness mock), but the FAMILY is pure data: a vehicle's
     mechanics actions fold under one family named for the VEHICLE (noun head),
     with the subcategories (Tires/Engine/Fuel/…) as right-side flavor in canonical
     order; two vehicles yield two families. ]]
local Assert = PZTestKit.Assert
local SP = require "palette/pal_vehicle_mechanics"
local Families = SP.Families

local function vmCmd(verb, part, vid, vname, cat)
    return { label = verb .. " - " .. part, kind = "vehmech", vehId = vid, vehName = vname,
             vmCat = cat, vmVerb = verb, source = vname }
end

local tests = {}

tests["family_registered_and_source_exists"] = function()
    if not Assert.notNil(Families and Families.apply, "Families.apply present") then return false end
    return Assert.notNil(SP.VehicleMechanics and SP.VehicleMechanics.collect, "vehmech source collect exists")
end

tests["noun_head_and_subcategory_flavor"] = function()
    local cmds = {
        vmCmd("Open Window",  "Front Left",      "7", "Pickup Truck", "Windows"),
        vmCmd("Uninstall",    "Front Left Tire", "7", "Pickup Truck", "Tires"),
        vmCmd("Add Gasoline", "Gas Tank",        "7", "Pickup Truck", "Fuel"),
    }
    Families.apply(cmds)
    local key
    for _, c in ipairs(cmds) do
        if not Assert.notNil(c.familyKey, "member stamped with familyKey") then return false end
        key = key or c.familyKey
        if not Assert.equal(c.familyKey, key, "all share one family key") then return false end
    end
    if not Assert.equal(cmds[1].familyLabel, "Pickup Truck", "head = the vehicle name") then return false end
    -- canonical order Tires(1), Fuel(4), Windows(6); capped to first 2 + "+N" so it
    -- doesn't crowd the vehicle name
    return Assert.equal(cmds[1].familyFlavor, "Tires, Fuel +1", "subcategory flavor capped, canonical order")
end

tests["two_vehicles_two_families"] = function()
    local cmds = {
        vmCmd("Uninstall", "Tire", "7", "Pickup Truck", "Tires"), vmCmd("Add Gasoline", "Gas Tank", "7", "Pickup Truck", "Fuel"),
        vmCmd("Uninstall", "Tire", "9", "Van", "Tires"),          vmCmd("Add Gasoline", "Gas Tank", "9", "Van", "Fuel"),
    }
    Families.apply(cmds)
    local keys = {}
    for _, c in ipairs(cmds) do if c.familyKey then keys[c.familyKey] = true end end
    local n = 0; for _ in pairs(keys) do n = n + 1 end
    return Assert.equal(n, 2, "two vehicles -> two distinct families")
end

return tests
