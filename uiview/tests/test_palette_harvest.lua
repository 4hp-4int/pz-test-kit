--[[
    SaucePalette harvest — generic "Craft" entry-point filter
    =========================================================
    The context-menu harvester must drop the bare "Craft" entry-point that some
    mods bolt onto every item (crafting is owned by the dedicated craft provider,
    which honestly hides station-gated recipes). It must NOT drop specific craft
    verbs like "Craft Crude Bandage" (those are real, distinct actions).
]]

local Assert = PZTestKit.Assert
local SP = require "palette/pal_harvest"
local isCraftEntry = SP.Harvest.isCraftEntry

local tests = {}

tests["bare_craft_entry_is_skipped"] = function()
    if not Assert.isTrue(isCraftEntry("Craft"), "'Craft' is a generic entry-point") then return false end
    if not Assert.isTrue(isCraftEntry("Crafting"), "'Crafting' too") then return false end
    return Assert.isTrue(isCraftEntry("  craft  "), "trimmed + case-insensitive")
end

tests["specific_craft_verbs_are_kept"] = function()
    if not Assert.isTrue(not isCraftEntry("Craft Crude Bandage"), "specific recipe verb kept") then return false end
    if not Assert.isTrue(not isCraftEntry("Open Box of Bullets"), "unrelated verb kept") then return false end
    return Assert.isTrue(not isCraftEntry("Equip Primary"), "equip verb kept")
end

-- Vanilla buries Favorite/Unfavorite under a generic "More >" overflow submenu.
-- A per-item harvest must source those verbs by the ITEM (so the palette shows
-- "Favorite > <item>"), not by the submenu name ("Favorite > More ... More").
tests["more_submenu_verbs_sourced_by_item_not_More"] = function()
    local item = { getName = function() return "Pistol" end, getTexture = function() return nil end }
    local moreSub = { options = { { name = "Favorite", onSelect = function() end } } }
    local ctx = {
        options    = { { name = "More", subOption = 1 } },   -- overflow submenu, no onSelect
        getSubMenu = function(_, so) return so == 1 and moreSub or nil end,
    }
    local out = {}
    SP.Harvest.flatten(ctx, item:getName(), item, out)

    local fav
    for _, c in ipairs(out) do if c.label == "Favorite" then fav = c end end
    if not Assert.equal(fav ~= nil, true, "Favorite harvested out of the More submenu") then return false end
    if not Assert.equal(fav.source, "Pistol", "sourced by the item, not 'More'") then return false end
    for _, c in ipairs(out) do
        if not Assert.equal(c.label ~= "More", true, "'More' overflow is not a command") then return false end
    end
    return true
end

-- A disabled vanilla option carries its WHY in opt.toolTip.description; a greyed
-- harvested row must surface that (cleaned of rich-text tags) instead of a dead grey
-- line you can't explain.
tests["disabled_option_surfaces_its_reason"] = function()
    local item = { getName = function() return "Saw" end, getTexture = function() return nil end }
    local ctx = { options = {
        { name = "Saw Logs", onSelect = function() end, notAvailable = true,
          toolTip = { description = "<RGB:1,0,0>You need a <LINE>sawhorse" } },
    } }
    local out = {}
    SP.Harvest.flatten(ctx, item:getName(), item, out)
    local saw
    for _, c in ipairs(out) do if c.label == "Saw Logs" then saw = c end end
    if not Assert.notNil(saw, "the disabled verb is still harvested (discoverable)") then return false end
    if not Assert.isTrue(saw.runnable == false, "notAvailable -> blocked") then return false end
    if not Assert.notNil(saw.blockReason, "blocked row carries a reason") then return false end
    if not Assert.isTrue(saw.blockReason:find("sawhorse", 1, true) ~= nil, "reason text extracted") then return false end
    return Assert.isTrue(saw.blockReason:find("<", 1, true) == nil, "rich-text tags stripped")
end

-- The 160-VHS-rows-off-one-tape bug: PZ's debug/admin "DBG: Change recording"
-- option (only present in debug/admin) bolts an enumeration submenu of every media
-- title onto media items. The harvest must drop DBG:/ADMIN: options AND their
-- submenus (they're added via plain addOption(), so the plumpabug-icon check misses
-- them). One leaked title, "A Stitch in Time", even tripped the medical keyword.
tests["debug_admin_option_and_its_submenu_are_skipped"] = function()
    local item = { getName = function() return "VHS Tape" end, getTexture = function() return nil end }
    local big = { options = { { name = "<NONE>", onSelect = function() end } } }
    for i = 1, 160 do big.options[#big.options + 1] = { name = "VHS: Title " .. i, onSelect = function() end } end
    local ctx = {
        options    = { { name = "Drop", onSelect = function() end },
                       { name = "DBG: Change recording", subOption = 1 } },   -- debug parent, no onSelect
        getSubMenu = function(_, so) return so == 1 and big or nil end,
    }
    local out = {}
    SP.Harvest.flatten(ctx, item:getName(), item, out)
    for _, c in ipairs(out) do
        if tostring(c.label):find("VHS: Title", 1, true) or c.label == "<NONE>"
           or tostring(c.label):find("Change recording", 1, true) then
            return Assert.isTrue(false, "a debug option / its submenu leaked: " .. c.label)
        end
    end
    local drop; for _, c in ipairs(out) do if c.label == "Drop" then drop = c end end
    return Assert.notNil(drop, "real top-level verbs still harvested (Drop)")
end

tests["small_verb_submenu_still_flattened"] = function()
    local item = { getName = function() return "Axe" end, getTexture = function() return nil end }
    local sub = { options = { { name = "Equip Primary", onSelect = function() end },
                              { name = "Equip Secondary", onSelect = function() end } } }
    local ctx = { options = { { name = "Equip", subOption = 1 } },
                  getSubMenu = function(_, so) return so == 1 and sub or nil end }
    local out = {}
    SP.Harvest.flatten(ctx, item:getName(), item, out)
    local prim; for _, c in ipairs(out) do if c.label == "Equip Primary" then prim = c end end
    return Assert.notNil(prim, "a small verb submenu is still flattened")
end

-- classifyAction: the keyword fallback (onSelect nil -> the identity map can't
-- match, so the conservative keyword rules decide the category). ------------
tests["classifyAction_keyword_fallback"] = function()
    if not Assert.equal(SP.classifyAction(nil, "Smoke Cigarette"), "use", "'smoke' -> use") then return false end
    if not Assert.equal(SP.classifyAction(nil, "Read Skill Book"), "read", "'read' -> read") then return false end
    if not Assert.equal(SP.classifyAction(nil, "Sip Water"), "drink", "'sip' -> drink") then return false end
    return Assert.equal(SP.classifyAction(nil, "Frobnicate Widget"), "action", "an unknown verb falls through to action")
end

-- H.run: execute the captured vanilla onSelect closure with its target+params.
tests["run_executes_onSelect_with_params"] = function()
    local got
    local cmd = { onSelect = function(target, a, b) got = { target, a, b } end, target = "T", params = { "x", "y" } }
    local ok = SP.Harvest.run(cmd)
    if not Assert.equal(ok, true, "run returns ok") then return false end
    if not Assert.equal(got[1], "T", "the option target is passed") then return false end
    return Assert.equal(got[2], "x", "param1 is passed through")
end

-- harvestInventory: drive a fake createMenu over the inventory tree ----------
local function invItem(ft, name)
    return { _type = "Item", getFullType = function() return ft end, getName = function() return name end,
             getDisplayName = function() return name end, getTexture = function() return nil end }
end

local function harvestEnv(menuOptions, items, opts, fn)
    opts = opts or {}
    local names = { "getSpecificPlayer", "ISInventoryPaneContextMenu", "UIManager", "instanceof", "getTimestampMs" }
    local saved = {}; for _, n in ipairs(names) do saved[n] = _G[n] end
    local ctx = { options = menuOptions, setVisible = function() end, hideAndChildren = function() end,
                  getSubMenu = function() return nil end }
    local container = {
        getItems = function() return { size = function() return #items end, get = function(_, i) return items[i + 1] end } end,
        getAllTypeRecurse = function() return { size = function() return opts.typeCount or 1 end,
                                                get = function() return items[1] end } end,
    }
    local p = { getInventory = function() return container end }
    _G.getSpecificPlayer = function() return p end
    _G.ISInventoryPaneContextMenu = { createMenu = function() return ctx end }
    _G.UIManager = { getSpeedControls = function() return { getCurrentGameSpeed = function() return opts.speed or 1 end } end }
    _G.instanceof = function(o, c) return type(o) == "table" and o._type == c end
    _G.getTimestampMs = function() return 0 end
    local out
    local ok, err = pcall(function() out = SP.Harvest.harvestInventory(0) end)
    for _, n in ipairs(names) do _G[n] = saved[n] end
    if not ok then error(err) end
    return fn(out)
end

tests["harvestInventory_collects_item_verbs"] = function()
    return harvestEnv(
        { { name = "Equip Primary", onSelect = function() end }, { name = "Drop", onSelect = function() end } },
        { invItem("Base.Axe", "Axe") }, {},
        function(out)
            if not Assert.equal(#out, 2, "both verbs harvested off the item") then return false end
            local by = {}; for _, c in ipairs(out) do by[c.label] = c end
            return Assert.notNil(by["Equip Primary"], "the equip verb is present")
        end)
end

tests["harvestInventory_dedupes_by_fulltype"] = function()
    return harvestEnv(
        { { name = "Equip Primary", onSelect = function() end } },
        { invItem("Base.Axe", "Axe"), invItem("Base.Axe", "Axe") }, {},
        function(out) return Assert.equal(#out, 1, "3 axes don't make 3x Equip — deduped by fulltype") end)
end

tests["harvestInventory_bails_while_paused"] = function()
    return harvestEnv(
        { { name = "Equip Primary", onSelect = function() end } },
        { invItem("Base.Axe", "Axe") }, { speed = 0 },
        function(out) return Assert.equal(#out, 0, "createMenu bails at speed 0 -> no harvest") end)
end

tests["repeatable_eat_verb_gets_a_batch_runN"] = function()
    return harvestEnv(
        { { name = "Eat Apple", onSelect = function() end } },
        { invItem("Base.Apple", "Apple") }, { typeCount = 5 },
        function(out)
            local eat; for _, c in ipairs(out) do if c.label == "Eat Apple" then eat = c end end
            if not Assert.notNil(eat, "the eat verb is harvested") then return false end
            if not Assert.equal(eat.maxN, 5, "maxN = held count (capped at 20)") then return false end
            return Assert.equal(type(eat.runN), "function", "a batch runN was attached to the consumable")
        end)
end

return tests
