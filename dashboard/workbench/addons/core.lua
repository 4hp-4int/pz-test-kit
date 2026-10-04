-- Kit-wide addon: works on any item, in any mod's VM.
-- Template for your own: copy this file into <your mod>/workbench/<name>.lua.

local function md(item) return item:getModData() end

WB.addon {
    id = "core",
    name = "Item basics",
    description = "modData and condition, for any item",
    -- A worn-out tool is the usual reason a chained craft refuses
    -- (crude wooden tongs: 1 condition, MayDegradeLight).
    badge = function(item)
        local ok, cur, max = pcall(function() return item:getCondition(), item:getConditionMax() end)
        if ok and max and max > 0 and cur <= 0 then return "broken", "fail" end
        return nil
    end,
    -- The model the game draws: held model for weapons, else the inventory
    -- static model, else the ground model (pzchar renders these).
    visual = function(item)
        local sc = item.getScriptItem and item:getScriptItem()
        if not sc then return nil end
        local function nz(f) local ok, v = pcall(f); if ok and v and tostring(v) ~= "" then return tostring(v) end end
        local m = nz(function() return sc:getWeaponSprite() end) or nz(function() return sc:getStaticModel() end)
            or nz(function() return sc:getWorldStaticModel() end)
        return m and { model = m } or nil
    end,
    panels = {
        {
            id = "moddata", title = "modData",
            render = function(item)
                local out, any = {}, false
                for k, v in pairs(md(item)) do out[k] = v; any = true end
                return any and out or nil
            end,
        },
    },
    actions = {
        {
            id = "mergeModData", label = "Merge modData",
            doc = "Shallow-merge a JSON object into item:getModData()",
            params = { { name = "data", type = "json", default = { key = 1 } } },
            run = function(item, p)
                local n = 0
                for k, v in pairs(p.data or {}) do md(item)[k] = v; n = n + 1 end
                return n .. " key(s) set"
            end,
        },
        {
            id = "clearModData", label = "Clear modData",
            run = function(item)
                local t, n = md(item), 0
                local keys = {}
                for k in pairs(t) do keys[#keys + 1] = k end
                for _, k in ipairs(keys) do t[k] = nil; n = n + 1 end
                return n .. " key(s) removed"
            end,
        },
        {
            id = "setCondition", label = "Set condition",
            params = { { name = "condition", type = "number", default = 1 } },
            appliesTo = function(item) return item.setCondition ~= nil end,
            run = function(item, p)
                item:setCondition(p.condition)
                return "condition " .. tostring(item:getCondition()) .. "/" .. tostring(item:getConditionMax())
            end,
        },
        {
            id = "setUses", label = "Set uses",
            doc = "Drainables (propane, batteries, crucibles): a recipe flagged NotFull refuses a full one",
            params = { { name = "uses", type = "number", default = 1 } },
            appliesTo = function(item) return instanceof(item, "DrainableComboItem") end,
            run = function(item, p)
                item:setCurrentUses(math.max(0, math.floor(tonumber(p.uses) or 0)))
                return "uses " .. tostring(item:getCurrentUses()) .. "/" .. tostring(item:getMaxUses())
            end,
        },
    },
}
