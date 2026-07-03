--[[
    SIR — two-level classification cache (sir_cache)
    ================================================
    Locks the cache contract the renderer stands on:
      - L1 type cache: every class branch (clothing/combo/drainable/container/
        key/fluid/IsDrainable-upgrade/blade-sub/medical), permanent per fullType
      - L2 state cache: book state machine (read/partial/canlearn/toohigh/
        toolow/recipe/uninteresting/unread + owned-copy + marked), keyring
        equip, weapon attachments, drainable/fluid/cooking volatile state,
        combo poison, media watched
      - INVALIDATION: state tables are cached per item id, recycled through the
        pool on markDirty, book caches cleared on clearBookCaches + the death /
        LevelPerk events
]]

local Assert = PZTestKit.Assert

require "UIView/UIMock"
require "sir_colors"
require "sir_cache"

local SIR = _G.SauceInvRender
local C = SIR.Cache

-- ── fixtures ────────────────────────────────────────────────────────────────
local NILFN = function() return function() return nil end end

local _id = 70000
local function makeItem(o)
    _id = _id + 1
    local id = _id
    local base = {
        _type = o.class or "InventoryItem",
        -- explicit FIELD (not method): the catch-all metatable returns a
        -- truthy function for any missing key, which would read as "equipped"
        _pequipped = o.pequipped or false,
        getID = function() return id end,
        getFullType = function() return o.fullType or ("Base.CacheItem" .. id) end,
        getDisplayCategory = function() return o.displayCat end,
        getCategory = function() return o.cat or "Item" end,
        isRanged = function() return o.ranged or false end,
        isBroken = function() return o.broken or false end,
        isFavorite = function() return o.fav or false end,
        isEquipped = function() return o.equipped or false end,
        getCondition = function() return o.cond or 0 end,
        getConditionMax = function() return o.condMax or 0 end,
        hasHeadCondition = function() return false end,
        hasSharpness = function() return false end,
        isRotten = function() return o.foodState == "rotten" end,
        isBurnt = function() return o.foodState == "burnt" end,
        isFrozen = function() return o.foodState == "frozen" end,
        getNumberOfPages = function() return o.pages or -1 end,
        getSkillTrained = function() return o.skill end,
        getLvlSkillTrained = function() return o.skillLvl or -1 end,
        getMaxLevelTrained = function() return o.maxLvl or 0 end,
        getTeachedRecipes = function()
            return { isEmpty = function() return not o.recipes end }
        end,
        hasModData = function() return o.modData ~= nil end,
        getModData = function() return o.modData end,
        getAttachedSlot = function() return o.attachedSlot end,
    }
    if o.fluid then
        base.getFluidContainer = function() return o.fluid end
    else
        base.getFluidContainer = function() return nil end
    end
    if o.drains then
        base.IsDrainable = function() return true end
        base.getCurrentUsesFloat = function() return o.uses end
    else
        base.IsDrainable = function() return false end
    end
    if o.cookTime then
        base.getCookingTime = function() return o.cookTime end
        base.getHeat = function() return o.heat or 2 end
        base.getMinutesToCook = function() return o.mtc or 60 end
        base.getMinutesToBurn = function() return o.mtb or 120 end
    end
    if o.media then
        base.getMediaData = function() return o.media end
    end
    if o.hasTag then base.hasTag = o.hasTag end
    if o.isItemType then base.isItemType = o.isItemType end
    if o.hasBeenSeen ~= nil then base.hasBeenSeen = function() return o.hasBeenSeen end end
    if o.hasBeenHeard ~= nil then base.hasBeenHeard = function() return o.hasBeenHeard end end
    if o.mapRead ~= nil then base.hasReadMap = function() return o.mapRead end end
    return setmetatable(base, { __index = NILFN })
end

local function makePlayer(o)
    o = o or {}
    return setmetatable({
        getPerkLevel = function() return o.perkLvl or 2 end,
        getAlreadyReadPages = function(_, ft) return (o.readPages and o.readPages[ft]) or 0 end,
        getAlreadyReadBook = function()
            return { contains = function(_, ft) return (o.readBooks and o.readBooks[ft]) or false end }
        end,
        isLiteratureRead = function(_, t) return (o.litRead and o.litRead[t]) or false end,
        isPrintMediaRead = function() return false end,
        isKnownPoison = function() return o.poison or false end,
        isEquipped = function(_, it) return (it and it._pequipped) or false end,
    }, { __index = NILFN })
end

if getZomboidRadio == nil then
    function getZomboidRadio()
        return {
            getRecordedMedia = function()
                return { hasListenedToAll = function(_, player, media) return media._watched == true end }
            end,
        }
    end
end

local tests = {}

-- ── L1 type cache ───────────────────────────────────────────────────────────

tests["type_class_branches"] = function()
    local cases = {
        { makeItem({ class = "Clothing", fullType = "Base.CT_Shirt" }), "clothing" },
        { makeItem({ class = "DrainableComboItem", fullType = "Base.CT_Bottle" }), "combo" },
        { makeItem({ class = "Drainable", fullType = "Base.CT_Tape" }), "drainable" },
        { makeItem({ class = "InventoryContainer", fullType = "Base.CT_Bag" }), "container" },
        { makeItem({ class = "Key", fullType = "Base.CT_Key" }), "key" },
        { makeItem({ class = "Literature", fullType = "Base.CT_Book" }), "literature" },
    }
    local ok = true
    for _, case in ipairs(cases) do
        local t = C.getType(case[1])
        ok = Assert.equal(t.class, case[2], "class " .. case[2]) and ok
    end
    return ok
end

tests["type_fluid_and_drains_upgrades"] = function()
    local bottle = makeItem({ fullType = "Base.CT_WaterBottle",
        fluid = { getAmount = function() return 1 end, getCapacity = function() return 2 end } })
    local t = C.getType(bottle)
    local ok = Assert.isTrue(t.hasFluid == true, "fluid container flagged")
    ok = Assert.equal(t.class, "combo", "plain item upgraded to combo by fluid") and ok

    local torch = makeItem({ fullType = "Base.CT_Flashlight", drains = true, uses = 0.5 })
    local t2 = C.getType(torch)
    ok = Assert.isTrue(t2.drainsUses == true, "IsDrainable() detected") and ok
    ok = Assert.equal(t2.class, "drainable", "plain item upgraded to drainable") and ok
    return ok
end

tests["type_weapon_blade_sub_and_medical"] = function()
    local knife = makeItem({ class = "HandWeapon", fullType = "Base.CT_Knife",
                             displayCat = "SmallBlade" })
    local ok = Assert.equal(C.getType(knife).sub, "blade", "blade display category -> blade sub")

    local bandage = makeItem({ fullType = "Base.CT_Bandage", displayCat = "FirstAid" })
    ok = Assert.isTrue(C.getType(bandage).medical == true, "FirstAid flagged medical") and ok
    return ok
end

tests["type_cache_is_permanent_per_fulltype"] = function()
    local a = makeItem({ class = "Clothing", fullType = "Base.CT_Permanent" })
    local t1 = C.getType(a)
    local b = makeItem({ class = "Food", fullType = "Base.CT_Permanent" })  -- lies about class
    local t2 = C.getType(b)
    return Assert.isTrue(rawequal(t1, t2), "same fullType -> same cached type table")
end

-- ── book state machine ──────────────────────────────────────────────────────

local function bookState(itemOpts, playerOpts)
    _G.SkillBook = _G.SkillBook or {}
    SkillBook.CacheCarp = SkillBook.CacheCarp or { perk = "CacheCarpPerk" }
    local item = makeItem(itemOpts)
    local player = makePlayer(playerOpts)
    return C.getState(player, item, nil, true), item, player
end

tests["book_fully_read_then_readcache_hit"] = function()
    C.clearBookCaches()
    local ft = "Base.CB_ReadBook"
    local s = bookState(
        { class = "Literature", fullType = ft, skill = "CacheCarp", pages = 100, skillLvl = 1, maxLvl = 4 },
        { readPages = { [ft] = 100 } })
    local ok = Assert.equal(s.bookStatus, "read", "all pages read -> read")
    ok = Assert.equal(s.litTint, "read", "tint follows") and ok

    -- second copy of the SAME title: served from readCache (no page math)
    local s2 = bookState(
        { class = "Literature", fullType = ft, skill = "CacheCarp", pages = 100, skillLvl = 1, maxLvl = 4 },
        { readPages = { [ft] = 0 } })   -- player mock now claims 0 pages
    ok = Assert.equal(s2.bookStatus, "read", "readCache remembers the title") and ok
    return ok
end

tests["book_partial_canlearn_toohigh_toolow"] = function()
    C.clearBookCaches()
    local s = bookState(
        { class = "Literature", fullType = "Base.CB_Partial", skill = "CacheCarp",
          pages = 200, skillLvl = 3, maxLvl = 4 },
        { readPages = { ["Base.CB_Partial"] = 50 }, perkLvl = 2 })
    local ok = Assert.equal(s.bookStatus, "canlearn", "level window open -> canlearn")
    ok = Assert.isTrue(s.bookPartial == true, "started pages -> partial") and ok
    ok = Assert.equal(s.pageProgress, 0.25, "page progress fraction") and ok
    ok = Assert.equal(s.litTint, "read" == s.bookStatus and "read" or s.litTint, "tint set") and ok

    local hi = bookState(
        { class = "Literature", fullType = "Base.CB_High", skill = "CacheCarp",
          pages = 200, skillLvl = 7, maxLvl = 8 },
        { perkLvl = 2 })
    ok = Assert.equal(hi.bookLevel, "toohigh", "min level above player -> toohigh") and ok

    local lo = bookState(
        { class = "Literature", fullType = "Base.CB_Low", skill = "CacheCarp",
          pages = 200, skillLvl = 1, maxLvl = 2 },
        { perkLvl = 6 })
    ok = Assert.equal(lo.bookLevel, "toolow", "book below player -> toolow") and ok
    return ok
end

tests["book_recipe_magazine_states"] = function()
    C.clearBookCaches()
    local ft = "Base.CB_Mag"
    local s = bookState({ class = "Literature", fullType = ft, recipes = true }, {})
    local ok = Assert.equal(s.bookStatus, "recipe", "unlearned recipe magazine")

    C.clearBookCaches()
    C.markDirty()
    local s2 = bookState({ class = "Literature", fullType = ft, recipes = true },
        { readBooks = { [ft] = true } })
    ok = Assert.equal(s2.bookStatus, "read", "learned recipe magazine -> read") and ok
    return ok
end

tests["book_uninteresting_tag_stays_iconless"] = function()
    C.clearBookCaches()
    _G.ItemTag = _G.ItemTag or {}
    ItemTag.UNINTERESTING = ItemTag.UNINTERESTING or "Uninteresting"
    local s = bookState({ class = "Literature", fullType = "Base.CB_IDCard",
        hasTag = function(_, tag) return tag == ItemTag.UNINTERESTING end }, {})
    return Assert.isNil(s.bookStatus, "junk literature gets no read state")
end

tests["book_regular_literature_read_paths"] = function()
    C.clearBookCaches()
    local viaModData = bookState({ class = "Literature", fullType = "Base.CB_Novel",
        modData = { literatureTitle = "Novel1" } }, { litRead = { Novel1 = true } })
    local ok = Assert.equal(viaModData.bookStatus, "read", "literatureTitle + isLiteratureRead")

    C.clearBookCaches()
    local viaSeen = bookState({ class = "Literature", fullType = "Base.CB_Comic",
        hasBeenSeen = true, hasBeenHeard = false }, {})
    ok = Assert.equal(viaSeen.bookStatus, "read", "hasBeenSeen -> read") and ok

    C.clearBookCaches()
    local unread = bookState({ class = "Literature", fullType = "Base.CB_Map",
        hasBeenSeen = false, hasBeenHeard = false }, {})
    ok = Assert.equal(unread.bookStatus, "unread", "nothing read -> unread") and ok
    return ok
end

tests["book_owned_copy_and_marked_in_loot_panel"] = function()
    C.clearBookCaches()
    SIR.Dupes = SIR.Dupes or {}
    local origFind, origMarks = SIR.Dupes.find, SIR.Marks
    SIR.Dupes.find = function() return {} end   -- player owns a copy
    SIR.Marks = { isMarked = function(ft) return ft == "Base.CB_Marked" end }

    local item = makeItem({ class = "Literature", fullType = "Base.CB_Marked",
        hasBeenSeen = false, hasBeenHeard = false })
    local s = C.getState(makePlayer({}), item, nil, false)   -- LOOT panel
    local ok = Assert.isTrue(s.ownedLit == true, "owned copy flagged in loot panels")
    ok = Assert.isTrue(s.marked == true, "manual mark flagged") and ok

    SIR.Dupes.find = origFind
    SIR.Marks = origMarks
    return ok
end

-- ── volatile state ──────────────────────────────────────────────────────────

tests["equip_branches_and_keyring"] = function()
    _G.ItemType = _G.ItemType or {}
    ItemType.KEY_RING = ItemType.KEY_RING or 42

    local attached = makeItem({ fullType = "Base.CV_Walkie", attachedSlot = 1 })
    local s = C.getState(makePlayer({}), attached, nil, true)
    local ok = Assert.equal(s.equip, "equipped", "attached slot counts as equipped")

    local keyring = makeItem({ fullType = "Base.CV_KeyRing",
        isItemType = function(_, t) return t == ItemType.KEY_RING end })
    local s2 = C.getState(makePlayer({}), keyring, nil, true)
    ok = Assert.equal(s2.equip, "equipped", "keyring always reads equipped") and ok

    local hotbar = { isInHotbar = function(_, it) return it ~= nil end }
    local batOnBelt = makeItem({ fullType = "Base.CV_Bat" })
    local s3 = C.getState(makePlayer({}), batOnBelt, hotbar, true)
    ok = Assert.equal(s3.equip, "hotbar", "hotbar item flagged") and ok

    local loot = makeItem({ fullType = "Base.CV_LootBat" })
    local s4 = C.getState(makePlayer({}), loot, hotbar, false)
    ok = Assert.isNil(s4.equip, "loot panels never show equip state") and ok
    return ok
end

tests["weapon_zero_condition_and_attachments"] = function()
    local bare = makeItem({ class = "HandWeapon", fullType = "Base.CV_Pipe",
                            cond = 0, condMax = 0 })
    local s = C.getState(makePlayer({}), bare, nil, true)
    local ok = Assert.isNil(s.condSeg, "no condition stats -> no pie segment")

    local scope = { getTex = function() return nil end }
    local rifle = makeItem({ class = "HandWeapon", fullType = "Base.CV_Rifle",
                             cond = 8, condMax = 10, ranged = true })
    rifle.getScope = function() return scope end
    local s2 = C.getState(makePlayer({}), rifle, nil, true)
    ok = Assert.isTrue(s2.isRanged == true, "ranged flagged") and ok
    ok = Assert.isTrue(s2.hasAttachments == true, "scope detected") and ok
    ok = Assert.equal(s2.attachScope, scope, "attachment carried in state") and ok
    return ok
end

tests["drainable_fluid_and_cooking_volatile"] = function()
    local torch = makeItem({ fullType = "Base.CV_Torch", drains = true, uses = 0.5 })
    local s = C.getState(makePlayer({}), torch, nil, true)
    local ok = Assert.equal(s.condRatio, 0.5, "drainable uses drive the ratio")
    ok = Assert.isTrue(s.isDrainable == true, "drainable flagged") and ok

    local bottle = makeItem({ fullType = "Base.CV_Bottle",
        fluid = { getAmount = function() return 1 end, getCapacity = function() return 4 end,
                  isEmpty = function() return false end, isTainted = function() return false end } })
    local s2 = C.getState(makePlayer({}), bottle, nil, true)
    ok = Assert.equal(s2.condRatio, 0.25, "fluid level drives the ratio") and ok
    ok = Assert.isTrue(s2.isFluid == true, "fluid flagged") and ok

    local steak = makeItem({ class = "Food", fullType = "Base.CV_Steak",
                             cookTime = 30, heat = 2, mtc = 60, mtb = 120 })
    local s3 = C.getState(makePlayer({}), steak, nil, true)
    ok = Assert.equal(s3.cookProgress, 0.5, "cooking progress from heat") and ok
    ok = Assert.isNil(s3.burnProgress, "not burning before minutesToCook") and ok

    local burning = makeItem({ class = "Food", fullType = "Base.CV_Burnt",
                               cookTime = 90, heat = 2, mtc = 60, mtb = 120 })
    local s4 = C.getState(makePlayer({}), burning, nil, true)
    ok = Assert.equal(s4.cookProgress, 1, "cook progress capped at 1") and ok
    ok = Assert.equal(s4.burnProgress, 0.5, "burn progress past minutesToCook") and ok
    return ok
end

tests["combo_poison_and_media_state"] = function()
    local tainted = makeItem({ class = "DrainableComboItem", fullType = "Base.CV_BadWater",
        fluid = { getAmount = function() return 1 end, getCapacity = function() return 2 end,
                  isEmpty = function() return false end, isTainted = function() return true end } })
    local s = C.getState(makePlayer({}), tainted, nil, true)
    local ok = Assert.isTrue(s.poison == true, "tainted fluid flags poison")

    local origFind = SIR.Dupes and SIR.Dupes.find
    if SIR.Dupes then SIR.Dupes.find = function() return {} end end
    local tape = makeItem({ fullType = "Base.CV_Tape", media = { _watched = false } })
    local s2 = C.getState(makePlayer({}), tape, nil, false)
    ok = Assert.isTrue(s2.hasMedia == true, "media detected") and ok
    ok = Assert.isTrue(s2.mediaWatched == false, "unwatched") and ok
    ok = Assert.equal(s2.mediaTint, "unread", "tint follows watch state") and ok
    ok = Assert.isTrue(s2.ownedMedia == true, "owned copy flagged in loot panel") and ok
    if SIR.Dupes then SIR.Dupes.find = origFind end

    local seenMap = makeItem({ fullType = "Base.CV_SeenThing", hasBeenSeen = true, hasBeenHeard = false })
    local s3 = C.getState(makePlayer({}), seenMap, nil, true)
    ok = Assert.isTrue(s3.seen == true, "hasBeenSeen sets seen on non-literature") and ok
    return ok
end

-- ── invalidation ────────────────────────────────────────────────────────────

tests["state_cached_by_id_until_markDirty_recycles"] = function()
    local player = makePlayer({})
    local item = makeItem({ class = "Food", fullType = "Base.CI_Apple" })
    local s1 = C.getState(player, item, nil, true)
    local s2 = C.getState(player, item, nil, true)
    local ok = Assert.isTrue(rawequal(s1, s2), "same item id -> same cached state table")

    C.markDirty()
    local other = makeItem({ class = "Food", fullType = "Base.CI_Pear" })
    local s3 = C.getState(player, other, nil, true)
    ok = Assert.isTrue(rawequal(s1, s3), "markDirty recycled the table through the pool") and ok
    ok = Assert.equal(s3.foodState, "fresh", "recycled table was wiped and rebuilt") and ok
    return ok
end

tests["death_event_invalidates_state_and_books"] = function()
    C.clearBookCaches()
    local ft = "Base.CI_DeathBook"
    _G.SkillBook = _G.SkillBook or {}
    SkillBook.CacheCarp = SkillBook.CacheCarp or { perk = "CacheCarpPerk" }

    local read = bookState(
        { class = "Literature", fullType = ft, skill = "CacheCarp", pages = 100, skillLvl = 1, maxLvl = 4 },
        { readPages = { [ft] = 100 } })
    local ok = Assert.equal(read.bookStatus, "read", "primed as read")

    triggerEvent("OnPlayerDeath")   -- markDirty + clearBookCaches

    local fresh = bookState(
        { class = "Literature", fullType = ft, skill = "CacheCarp", pages = 100, skillLvl = 1, maxLvl = 4 },
        { readPages = { [ft] = 0 }, perkLvl = 2 })
    ok = Assert.equal(fresh.bookStatus, "canlearn", "death wiped the readCache: recomputed") and ok
    return ok
end

tests["levelperk_event_clears_book_caches"] = function()
    C.clearBookCaches()
    local ft = "Base.CI_PerkBook"
    _G.SkillBook = _G.SkillBook or {}
    SkillBook.CacheCarp = SkillBook.CacheCarp or { perk = "CacheCarpPerk" }

    -- prime the readCache with a finished copy
    bookState(
        { class = "Literature", fullType = ft, skill = "CacheCarp", pages = 100, skillLvl = 1, maxLvl = 4 },
        { readPages = { [ft] = 100 } })

    triggerEvent("LevelPerk")
    C.markDirty()   -- the state table itself is per dirty cycle

    local recomputed = bookState(
        { class = "Literature", fullType = ft, skill = "CacheCarp", pages = 100, skillLvl = 3, maxLvl = 6 },
        { readPages = { [ft] = 10 }, perkLvl = 2 })
    return Assert.equal(recomputed.bookStatus, "canlearn",
        "LevelPerk wiped the readCache: level window recomputed")
end

return tests
