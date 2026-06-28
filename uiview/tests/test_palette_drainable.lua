--[[ pal_drainable — the combo-drainable consolidation family ADAPTER. It
     recognizes harvested vanilla consolidate options by their onSelect identity
     (onConsolidate / onConsolidateAll) and folds them into one "Consolidate
     <Item>" family per drainable type, default = Merge All. ]]
local Assert = PZTestKit.Assert
local SP = require "palette/pal_drainable"
local Families = SP.Families

-- stub the two vanilla handlers the adapter keys on
local onConsolidate    = function() end
local onConsolidateAll = function() end
_G.ISInventoryPaneContextMenu = _G.ISInventoryPaneContextMenu or {}
_G.ISInventoryPaneContextMenu.onConsolidate    = onConsolidate
_G.ISInventoryPaneContextMenu.onConsolidateAll = onConsolidateAll

local function drainable(typ, name)
    return { getType = function() return typ end, getName = function() return name end }
end
-- a harvested option: onSelect identity + target (the drainable being poured)
local function pourCmd(label, onSel, typ, name)
    return { label = label, onSelect = onSel, target = drainable(typ, name), source = "Pour into" }
end

local tests = {}

tests["adapter_present"] = function()
    return Assert.notNil(Families and Families.apply, "Families.apply present")
end

tests["consolidate_options_collapse_merge_all_default"] = function()
    local cmds = {
        pourCmd("Merge All",        onConsolidateAll, "Thread", "Thread"),
        pourCmd("Thread (90%)",     onConsolidate,    "Thread", "Thread"),
        pourCmd("Thread (40%)",     onConsolidate,    "Thread", "Thread"),
    }
    Families.apply(cmds)
    local key, def
    for _, c in ipairs(cmds) do
        if not Assert.notNil(c.familyKey, "consolidate option stamped with familyKey") then return false end
        key = key or c.familyKey
        if not Assert.equal(c.familyKey, key, "all share one family key (per drainable type)") then return false end
        if c.familyDefault then def = c end
    end
    if not Assert.equal(cmds[1].familyLabel, "Consolidate Thread", "head = Consolidate <Item>") then return false end
    if not Assert.notNil(def, "a default was chosen") then return false end
    return Assert.equal(def.label, "Merge All", "Merge All is the default (consolidate-all)")
end

tests["non_consolidate_command_untouched"] = function()
    local other = { label = "Equip Hammer", onSelect = function() end, target = {} }
    local cmds = { other }
    Families.apply(cmds)
    return Assert.isNil(other.familyKey, "a non-consolidate command is not adopted")
end

return tests
