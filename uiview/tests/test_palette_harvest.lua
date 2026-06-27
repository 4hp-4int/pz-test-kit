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

return tests
