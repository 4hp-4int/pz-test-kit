--[[ pal_loot — the "Loot <Container>" family. collect() reads the live loot panel
     (no harness mock), but the family that collapses a container's take actions is
     pure data: Take All + category buckets fold under "Loot <Container>", Take All
     is the default (sorts first), two containers -> two families. ]]
local Assert = PZTestKit.Assert
local SP = require "palette/pal_loot"
local Families = SP.Families

local function lootCmd(label, key, name, isAll)
    return { label = label, kind = "loot", lootKey = key, lootName = name, lootAll = isAll or false, source = name }
end

-- collect-driven coverage: feed the live loot panel a fixture container and run
-- the real collect() (Take All + per-item rows).
local Fixtures = PZTestKit.Fixtures
local function lootCollect()
    for _, s in ipairs(SP.sources) do if s.id == "loot" then return s.collect end end
end
local function collectLive(fulltypes, typeName)
    _G.ISInventoryTransferAction = _G.ISInventoryTransferAction or {}
    local cont = Fixtures.container({ typeName = typeName or "crate" })
    -- distinct ids: the container's dup-ID guard would drop items sharing the
    -- harness's default id (ZombRand is nil offline).
    for i, ft in ipairs(fulltypes) do cont:AddItem(Fixtures.item({ fullType = ft, id = 1000 + i })) end
    _G.getPlayerLoot = function(_)
        return { inventoryPane = { inventoryPage = { backpacks = { { inventory = cont } } } } }
    end
    _G._pz_player = Fixtures.player({})
    return lootCollect()(0)
end
local function find(cmds, sub)
    for _, c in ipairs(cmds) do if tostring(c.label):find(sub, 1, true) then return c end end
    return nil
end

-- a fake worn/held bag: instanceof "InventoryContainer" + getInventory() -> its cont
local function bagItem(name, cap, used)
    local cont = { _type = "ItemContainer",
        getCapacity = function() return cap or 50 end,
        getCapacityWeight = function() return used or 0 end,
    }
    return { _type = "InventoryContainer", getName = function() return name end,
             getInventory = function() return cont end }, cont
end

-- collect() with a bag held in the primary hand (a loot destination).
local function collectLiveBagged(fulltypes, bag)
    _G.ISInventoryTransferAction = _G.ISInventoryTransferAction or {}
    local cont = Fixtures.container({ typeName = "crate" })
    for i, ft in ipairs(fulltypes) do cont:AddItem(Fixtures.item({ fullType = ft, id = 2000 + i })) end
    _G.getPlayerLoot = function(_)
        return { inventoryPane = { inventoryPage = { backpacks = { { inventory = cont } } } } }
    end
    local p = Fixtures.player({})
    p:setPrimaryHandItem(bag)
    _G._pz_player = p
    return lootCollect()(0)
end

local tests = {}

tests["source_and_family_present"] = function()
    if not Assert.notNil(SP.Loot and SP.Loot.collect, "loot source collect exists") then return false end
    return Assert.notNil(Families and Families.apply, "Families.apply present")
end

tests["container_collapses_take_all_is_default"] = function()
    local cmds = {
        lootCmd("Take All - Fridge (12)", 1, "Fridge", true),
        lootCmd("Take all Food (5)",      1, "Fridge"),
        lootCmd("Take all Tools (4)",     1, "Fridge"),
    }
    Families.apply(cmds)
    local key, def
    for _, c in ipairs(cmds) do
        if not Assert.notNil(c.familyKey, "member stamped with familyKey") then return false end
        key = key or c.familyKey
        if not Assert.equal(c.familyKey, key, "all take actions share one family key") then return false end
        if c.familyDefault then def = c end
    end
    if not Assert.equal(cmds[1].familyLabel, "Loot Fridge", "family head = Loot <Container>") then return false end
    if not Assert.notNil(def, "a default was chosen") then return false end
    return Assert.equal(def.label, "Take All - Fridge (12)", "Take All names the container (reads standalone)")
end

tests["two_containers_two_families"] = function()
    local cmds = {
        lootCmd("Take All (3)", 1, "Crate", true), lootCmd("Take all Tools (3)", 1, "Crate"),
        lootCmd("Take All (8)", 2, "Floor", true), lootCmd("Take all Food (8)",  2, "Floor"),
    }
    Families.apply(cmds)
    local keys = {}
    for _, c in ipairs(cmds) do if c.familyKey then keys[c.familyKey] = true end end
    local n = 0; for _ in pairs(keys) do n = n + 1 end
    return Assert.equal(n, 2, "two containers -> two distinct families")
end

-- ── collect() driven (real source over a fixture container) ──────────────────
tests["collect_take_all_and_per_item"] = function()
    local cmds = collectLive({ "Base.Nails", "Base.Hammer" })
    if not Assert.notNil(find(cmds, "Take All"), "non-empty container -> Take All") then return false end
    if not Assert.notNil(find(cmds, "Nails"), "per-item Take Nails") then return false end
    return Assert.notNil(find(cmds, "Hammer"), "per-item Take Hammer")
end

tests["collect_single_type_skips_per_item"] = function()
    local cmds = collectLive({ "Base.Nails", "Base.Nails" })
    if not Assert.notNil(find(cmds, "Take All"), "Take All present") then return false end
    return Assert.equal(#cmds, 1, "single-type container -> only Take All (no redundant per-item)")
end

tests["collect_empty_container_nothing"] = function()
    return Assert.equal(#collectLive({}), 0, "empty container -> no loot rows")
end

-- ── destination targeting (loot straight into a chosen bag) ──────────────────
tests["destinations_no_bag_is_empty"] = function()
    local p = { getInventory = function() return { _type = "ItemContainer" } end,
                getClothingItem_Back = function() return nil end,
                getPrimaryHandItem = function() return nil end,
                getSecondaryHandItem = function() return nil end }
    local _, bags = SP.Loot.destinations(p)
    return Assert.equal(#bags, 0, "no worn/held bag -> no extra destinations")
end

tests["destinations_orders_roomiest_first"] = function()
    local small = bagItem("Satchel", 10, 8)   -- 2 free
    local big   = bagItem("Duffel Bag", 50, 5) -- 45 free
    local inv = { _type = "ItemContainer" }
    local p = { getInventory = function() return inv end,
                getClothingItem_Back = function() return (big) end,
                getPrimaryHandItem = function() return (small) end,
                getSecondaryHandItem = function() return nil end }
    local rInv, bags = SP.Loot.destinations(p)
    if not Assert.equal(rInv, inv, "body inventory returned") then return false end
    if not Assert.equal(#bags, 2, "two bags found") then return false end
    return Assert.equal(bags[1].name, "Duffel Bag", "roomiest bag sorts first (becomes the default)")
end

tests["collect_bagged_offers_bag_and_body"] = function()
    local bag = bagItem("Duffel Bag", 50, 0)
    local cmds = collectLiveBagged({ "Base.Nails", "Base.Hammer" }, bag)
    if not Assert.notNil(find(cmds, "Take All to Duffel Bag"), "Take All into the bag (the default)") then return false end
    return Assert.notNil(find(cmds, "Take All to Inventory"), "Take All into the body offered as override")
end

tests["collect_bagged_default_is_the_bag"] = function()
    local bag = bagItem("Duffel Bag", 50, 0)
    Families.apply(collectLiveBagged({ "Base.Nails", "Base.Hammer" }, bag))
    -- the default (lootAll) Take All targets the bag, not the body
    local cmds = collectLiveBagged({ "Base.Nails", "Base.Hammer" }, bag)
    local def
    for _, c in ipairs(cmds) do if c.lootAll then def = c end end
    if not Assert.notNil(def, "a default Take All exists") then return false end
    return Assert.notNil(tostring(def.label):find("Duffel Bag", 1, true), "default loots into the roomiest bag")
end

-- ── item-metadata detail (the tooltip-style preview) ────────────────────────
local function hasRow(d, text, qty)
    for _, r in ipairs(d.rows) do
        if r.text == text and (qty == nil or r.qty == qty) then return true end
    end
    return false
end

tests["item_detail_fresh_food"] = function()
    local saved = _G.instanceof
    _G.instanceof = function(o, cls) return cls == "Food" and o._food == true end
    local apple = { _food = true, getName = function() return "Apple" end,
        getOffAge = function() return 100 end, getAge = function() return 10 end,
        isFrozen = function() return false end, isRotten = function() return false end,
        getHungerChange = function() return -0.4 end, getActualWeight = function() return 0.3 end }
    local d = SP.Loot.itemDetail(apple, 1, "Fridge")
    _G.instanceof = saved
    return Assert.isTrue(hasRow(d, "fresh"), "a fresh apple reads fresh")
end

tests["item_detail_non_perishable_not_rotten"] = function()
    -- the 1e9 sentinel guard: a can with a huge age must NOT read rotten.
    local saved = _G.instanceof
    _G.instanceof = function(o, cls) return cls == "Food" and o._food == true end
    local can = { _food = true, getName = function() return "Canned Beans" end,
        getOffAge = function() return 1000000000 end, getAge = function() return 50000 end,
        isFrozen = function() return false end, isRotten = function() return false end }
    local d = SP.Loot.itemDetail(can, 1, "Crate")
    _G.instanceof = saved
    if not Assert.isTrue(hasRow(d, "non-perishable"), "offAge 1e9 reads non-perishable") then return false end
    return Assert.isFalse(hasRow(d, "rotten"), "...and never rotten")
end

tests["item_detail_condition"] = function()
    local saved = _G.instanceof
    _G.instanceof = function() return false end   -- not Food / not Drainable
    local axe = { getName = function() return "Axe" end, getCondition = function() return 4 end,
        getConditionMax = function() return 10 end, getActualWeight = function() return 3 end }
    local d = SP.Loot.itemDetail(axe, 1, "Crate")
    _G.instanceof = saved
    return Assert.isTrue(hasRow(d, "condition", "4/10"), "a worn axe shows its condition")
end

tests["item_detail_drainable_charge"] = function()
    -- the drainable path uses getCurrentUsesFloat/getMaxUses (there is NO getUsedDelta
    -- getter — that was a render-crash). A half-used lighter reads ~50% remaining.
    local saved = _G.instanceof
    _G.instanceof = function(o, cls) return cls == "DrainableComboItem" and o._drain == true end
    local f = function(v) return function() return v end end
    local lighter = { _drain = true, getName = f("Lighter"),
        getCurrentUsesFloat = f(5), getMaxUses = f(10), getActualWeight = f(0.1) }
    local d = SP.Loot.itemDetail(lighter, 1, "Crate")
    _G.instanceof = saved
    return Assert.isTrue(hasRow(d, "remaining", "50%"), "a half-used drainable reads 50% remaining")
end

tests["contents_detail_groups_duplicates"] = function()
    local items = {
        { getName = function() return "Nails" end }, { getName = function() return "Nails" end },
        { getName = function() return "Hammer" end },
    }
    local d = SP.Loot.contentsDetail(items, "Take All", "Crate")
    return Assert.isTrue(hasRow(d, "Nails", "x2"), "the haul preview groups duplicates with counts")
end

return tests
