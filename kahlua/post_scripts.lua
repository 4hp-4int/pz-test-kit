--[[
    PZ Test Kit — Post-Scripts Hook
    ================================
    Runs AFTER all weapon/item scripts and mod-factory overrides have loaded.

    Purpose: when a mod defines its own `instanceItem` factory (VPS does this
    via weapon_factory.lua to add custom script data), any wrap we applied
    earlier gets replaced. This hook wraps the final `instanceItem` so strict
    mode can still seal returned objects, regardless of who owns the factory.
]]

if _pz_strict_mocks and type(instanceItem) == "function" then
    local _orig_instanceItem = instanceItem
    instanceItem = function(fullType)
        local obj = _orig_instanceItem(fullType)
        if type(obj) == "table" then
            local kind = "Item"
            if obj._type == "HandWeapon" or (type(obj.IsWeapon) == "function" and obj:IsWeapon()) then
                kind = "HandWeapon"
            elseif obj._type == "InventoryItem" then
                kind = "InventoryItem"
            end
            _pz_seal_mock(obj, kind)
        end
        return obj
    end
    print("[PZTestKit] Sealed instanceItem returns (strict mode post-scripts)")
end
