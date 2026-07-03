--[[
    SIR — duplicate tracking (sir_dupes) + dupe provider resolution
    ===============================================================
    Drives the REAL scan/find index over mock player inventories: best-condition
    wins for weapons/clothing, first-wins for everything else, worn-bag
    recursion, the scan throttle (time + item-count triggers), the death wipe,
    and SIR.resolveDupe's better/worse/equal verdicts + Mod Options gating.
]]

local Assert = PZTestKit.Assert

require "UIView/UIMock"

-- controllable clock for the scan throttle (sir_dupes reads it per call)
local _nowMs = 0
function getTimeInMillis() return _nowMs end

require "sir_providers"   -- pulls sir_icons + sir_layout + sir_dupes

local SIR = _G.SauceInvRender
local D = SIR.Dupes
local I = SIR.Icons

-- ── fixtures ────────────────────────────────────────────────────────────────
local NILFN = function() return function() return nil end end

local _id = 5000
local function makeItem(o)
    _id = _id + 1
    local base = {
        _type = o.class or "InventoryItem",
        getID = function() return _id end,
        getFullType = function() return o.fullType end,
        getType = function() return o.fullType end,
        getCondition = function() return o.cond or 0 end,
        getConditionMax = function() return o.condMax or 10 end,
        isEquipped = function() return o.equipped or false end,
        getInventory = function() return o.inv end,
    }
    return setmetatable(base, { __index = NILFN })
end

local function makeInv(items)
    return {
        getItems = function()
            return {
                size = function() return #items end,
                get = function(_, i) return items[i + 1] end,
            }
        end,
    }
end

local function makePlayer(inv, dead)
    return {
        getPlayerNum = function() return 0 end,
        isDead = function() return dead or false end,
        getInventory = function() return inv end,
    }
end

-- fresh index per test: scan an empty inventory (clears), then the fixture
local function scanWith(items)
    local player = makePlayer(makeInv(items))
    D.scan(player)
    return player
end

local tests = {}

tests["scan_keeps_best_condition_weapon"] = function()
    local worn = makeItem({ class = "HandWeapon", fullType = "Base.Axe", cond = 3 })
    local mint = makeItem({ class = "HandWeapon", fullType = "Base.Axe", cond = 8 })
    scanWith({ worn, mint })
    local loot = makeItem({ class = "HandWeapon", fullType = "Base.Axe", cond = 5 })
    local ok = Assert.equal(D.find(loot), mint, "index holds the highest-condition copy")
    ok = Assert.isNil(D.find(mint), "the indexed item never matches itself") and ok
    ok = Assert.equal(D.find(worn), mint, "a different owned copy still resolves to the best") and ok
    return ok
end

tests["scan_order_independent_for_condition"] = function()
    local mint = makeItem({ class = "HandWeapon", fullType = "Base.Axe", cond = 8 })
    local worn = makeItem({ class = "HandWeapon", fullType = "Base.Axe", cond = 3 })
    scanWith({ mint, worn })   -- best FIRST: the replace branch must not regress
    local loot = makeItem({ class = "HandWeapon", fullType = "Base.Axe", cond = 5 })
    return Assert.equal(D.find(loot), mint, "best copy kept regardless of scan order")
end

tests["first_wins_for_conditionless_items"] = function()
    local a = makeItem({ class = "Food", fullType = "Base.Apple" })
    local b = makeItem({ class = "Food", fullType = "Base.Apple" })
    scanWith({ a, b })
    local loot = makeItem({ class = "Food", fullType = "Base.Apple" })
    return Assert.equal(D.find(loot), a, "no condition contest: first indexed copy wins")
end

tests["worn_bag_contents_indexed"] = function()
    local knife = makeItem({ class = "HandWeapon", fullType = "Base.HuntingKnife", cond = 7 })
    local bag = makeItem({ class = "InventoryContainer", fullType = "Base.Bag_Duffel",
                           equipped = true, inv = makeInv({ knife }) })
    scanWith({ bag })
    local loot = makeItem({ class = "HandWeapon", fullType = "Base.HuntingKnife", cond = 2 })
    return Assert.equal(D.find(loot), knife, "recursed into the equipped bag")
end

tests["unworn_bag_indexed_but_not_recursed"] = function()
    local knife = makeItem({ class = "HandWeapon", fullType = "Base.HuntingKnife", cond = 7 })
    local bag = makeItem({ class = "InventoryContainer", fullType = "Base.Bag_Duffel",
                           equipped = false, inv = makeInv({ knife }) })
    scanWith({ bag })
    local lootKnife = makeItem({ class = "HandWeapon", fullType = "Base.HuntingKnife", cond = 2 })
    local lootBag = makeItem({ class = "InventoryContainer", fullType = "Base.Bag_Duffel" })
    local ok = Assert.isNil(D.find(lootKnife), "contents of an unworn bag are not indexed")
    ok = Assert.equal(D.find(lootBag), bag, "the unworn bag itself IS indexed") and ok
    return ok
end

tests["find_requires_getFullType"] = function()
    scanWith({ makeItem({ class = "Food", fullType = "Base.Apple" }) })
    return Assert.isNil(D.find({}), "no getFullType -> nil, no crash")
end

tests["dead_player_scan_is_a_noop"] = function()
    local axe = makeItem({ class = "HandWeapon", fullType = "Base.Axe", cond = 8 })
    scanWith({ axe })
    D.scan(makePlayer(makeInv({}), true))   -- dead: returns before clearing
    local loot = makeItem({ class = "HandWeapon", fullType = "Base.Axe", cond = 5 })
    return Assert.equal(D.find(loot), axe, "index untouched by a dead-player scan")
end

tests["scanIfNeeded_throttles_by_time_and_count"] = function()
    _nowMs = 100000
    local axe = makeItem({ class = "HandWeapon", fullType = "Base.Axe", cond = 8 })
    local items = { axe }
    local player = makePlayer(makeInv(items))

    D.scan(player)                       -- prime lastScanPlayerNum
    D.scanIfNeeded(player, 1)            -- records count + time
    items[2] = makeItem({ class = "Food", fullType = "Base.Apple" })

    _nowMs = _nowMs + 200                -- inside the 1s window, same count
    D.scanIfNeeded(player, 1)
    local lootApple = makeItem({ class = "Food", fullType = "Base.Apple" })
    local ok = Assert.isNil(D.find(lootApple), "within throttle window: stale index kept")

    D.scanIfNeeded(player, 2)            -- item count changed -> rescan now
    ok = Assert.notNil(D.find(lootApple), "count change forces a rescan") and ok

    items[3] = makeItem({ class = "Food", fullType = "Base.Pear" })
    _nowMs = _nowMs + 1500               -- past the interval, same count
    D.scanIfNeeded(player, 2)
    local lootPear = makeItem({ class = "Food", fullType = "Base.Pear" })
    ok = Assert.notNil(D.find(lootPear), "elapsed interval forces a rescan") and ok
    return ok
end

tests["death_event_wipes_the_index"] = function()
    local axe = makeItem({ class = "HandWeapon", fullType = "Base.Axe", cond = 8 })
    scanWith({ axe })
    triggerEvent("OnPlayerDeath")
    local loot = makeItem({ class = "HandWeapon", fullType = "Base.Axe", cond = 5 })
    return Assert.isNil(D.find(loot), "OnPlayerDeath clears the dupe index")
end

-- ── SIR.resolveDupe: the comparison verdict icons ───────────────────────────

local function optDefaults()
    SIR.Options = {
        trackDuplicates = true, trackDuplicatesWeapons = true,
        trackDuplicatesClothing = true, trackDuplicatesOther = true,
    }
end

tests["resolveDupe_weapon_verdicts"] = function()
    optDefaults()
    local owned = makeItem({ class = "HandWeapon", fullType = "Base.Axe", cond = 5 })
    scanWith({ owned })
    local tc = { class = "weapon" }

    local worse = makeItem({ class = "HandWeapon", fullType = "Base.Axe", cond = 2 })
    local tex, r, g, b = SIR.resolveDupe(worse, tc, {}, nil)
    local ok = Assert.equal(tex, I.cmpWorse, "lower condition -> worse icon")
    ok = Assert.equal(g, 0.5, "worse tint is reddish") and ok

    local better = makeItem({ class = "HandWeapon", fullType = "Base.Axe", cond = 9 })
    tex = SIR.resolveDupe(better, tc, {}, nil)
    ok = Assert.equal(tex, I.cmpBetter, "higher condition -> better icon") and ok

    local equal = makeItem({ class = "HandWeapon", fullType = "Base.Axe", cond = 5 })
    tex = SIR.resolveDupe(equal, tc, {}, nil)
    ok = Assert.equal(tex, I.cmpEqual, "same condition -> equal icon") and ok

    local unowned = makeItem({ class = "HandWeapon", fullType = "Base.Crowbar", cond = 5 })
    ok = Assert.isNil(SIR.resolveDupe(unowned, tc, {}, nil), "no owned copy -> no icon") and ok
    return ok
end

tests["resolveDupe_clothing_conditionless_falls_to_hand"] = function()
    optDefaults()
    local owned = makeItem({ class = "Clothing", fullType = "Base.Socks", cond = 0, condMax = 0 })
    scanWith({ owned })
    local loot = makeItem({ class = "Clothing", fullType = "Base.Socks", cond = 0, condMax = 0 })
    local tex = SIR.resolveDupe(loot, { class = "clothing" }, {}, nil)
    local ok = Assert.equal(tex, I.dupHand, "conditionless clothing -> plain dupe hand")

    local ownedShirt = makeItem({ class = "Clothing", fullType = "Base.Shirt", cond = 8, condMax = 10 })
    scanWith({ ownedShirt })
    local wornShirt = makeItem({ class = "Clothing", fullType = "Base.Shirt", cond = 3, condMax = 10 })
    tex = SIR.resolveDupe(wornShirt, { class = "clothing" }, {}, nil)
    ok = Assert.equal(tex, I.cmpWorse, "conditioned clothing compares like weapons") and ok
    return ok
end

tests["resolveDupe_generic_hand_icon"] = function()
    optDefaults()
    local owned = makeItem({ class = "Food", fullType = "Base.Apple" })
    scanWith({ owned })
    local loot = makeItem({ class = "Food", fullType = "Base.Apple" })
    local tex = SIR.resolveDupe(loot, { class = "food" }, {}, nil)
    local ok = Assert.equal(tex, I.dupHand, "generic dupe -> hand icon")
    ok = Assert.isNil(SIR.resolveDupe(loot, { class = "weirdclass" }, {}, nil),
        "unhandled class -> no provider claims it") and ok
    return ok
end

tests["resolveDupe_respects_mod_options"] = function()
    optDefaults()
    local owned = makeItem({ class = "HandWeapon", fullType = "Base.Axe", cond = 5 })
    scanWith({ owned })
    local loot = makeItem({ class = "HandWeapon", fullType = "Base.Axe", cond = 2 })

    SIR.Options.trackDuplicatesWeapons = false
    local ok = Assert.isNil(SIR.resolveDupe(loot, { class = "weapon" }, {}, nil),
        "weapon toggle off -> weapon dupes silent")

    SIR.Options.trackDuplicatesWeapons = true
    SIR.Options.trackDuplicates = false
    ok = Assert.isNil(SIR.resolveDupe(loot, { class = "weapon" }, {}, nil),
        "master toggle off -> all dupes silent") and ok

    optDefaults()
    return ok
end

return tests
