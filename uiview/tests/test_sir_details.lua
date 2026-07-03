--[[
    SIR — detail-line providers (sir_details) + resolveDetail dispatch
    ==================================================================
    Calls SIR.resolveDetail with hand-built tc/state and a recording pane:
    every registered detail provider renders its branch (weapon stats +
    attachment strip, food cooking/freezing/burnt, nutrition, clothing
    defense, literature pages/skill/progress, container preview, drainable
    and fluid bars, magazine ammo), and dispatch picks the highest-priority
    enabled provider.
]]

local Assert = PZTestKit.Assert

require "UIView/UIMock"
if getText == nil then function getText(k) return tostring(k) end end

require "sir_colors"     -- SIR.Colors.drawStatBar (multi-stat weapon bars)
require "sir_render"     -- SIR.fitText
require "sir_details"

local SIR = _G.SauceInvRender

-- ── fixtures ────────────────────────────────────────────────────────────────
local NILFN = function() return function() return nil end end

local function makeItem(fields)
    return setmetatable(fields, { __index = NILFN })
end

-- recording pane: only the draw surface the detail providers touch
local function makePane()
    local p = { font = "Small", itemHgt = 36, fontHgt = 14,
                texts = {}, bars = {}, texes = {}, rects = {} }
    function p:drawText(str, ...) self.texts[#self.texts + 1] = tostring(str) end
    function p:drawTextAndProgressBar(label, fraction, x, y, fgText, fgBar)
        self.bars[#self.bars + 1] = { label = tostring(label), fraction = fraction }
    end
    function p:drawTextureScaledAspect(tex, ...) self.texes[#self.texes + 1] = tostring(tex) end
    function p:drawRect(...) self.rects[#self.rects + 1] = true end
    function p:drawRectBorder(...) end
    return p
end

local function textsJoined(p) return table.concat(p.texts, " | ") end

local function resolve(item, tc, state, pane)
    pane = pane or makePane()
    local handled = SIR.resolveDetail(pane, item, tc, state or {}, 40, 10, 380, 24)
    return handled, pane
end

local tests = {}

-- ── weapon ──────────────────────────────────────────────────────────────────

tests["weapon_stats_line"] = function()
    local item = makeItem({
        getMinDamage = function() return 0.5 end,
        getMaxDamage = function() return 1.2 end,
        getCriticalChance = function() return 20 end,
        getActualWeight = function() return 1.5 end,
    })
    local handled, p = resolve(item, { class = "weapon" }, {})
    local ok = Assert.isTrue(handled, "weapon provider claimed the row")
    local line = textsJoined(p)
    ok = Assert.isTrue(line:find("Dmg: 0.5 - 1.2", 1, true) ~= nil, "damage range rendered") and ok
    ok = Assert.isTrue(line:find("Crit: 20", 1, true) ~= nil, "crit rendered") and ok
    ok = Assert.isTrue(line:find("1.50 kg", 1, true) ~= nil, "weight rendered") and ok
    return ok
end

tests["weapon_multistat_bars_and_range"] = function()
    local item = makeItem({
        getMinDamage = function() return 0.5 end,
        getMaxDamage = function() return 1.2 end,
        getCriticalChance = function() return 0 end,
        getMaxRange = function() return 8.5 end,
        getActualWeight = function() return 3 end,
    })
    local state = {
        condCount = 2,
        allConditions = { 0.5, 0.9, _kinds = { "condition", "head" } },
        isRanged = true,
    }
    local handled, p = resolve(item, { class = "weapon" }, state)
    local ok = Assert.isTrue(handled, "handled")
    ok = Assert.isTrue(textsJoined(p):find("Range: 8.5", 1, true) ~= nil, "ranged range stat") and ok
    ok = Assert.isTrue(textsJoined(p):find("Cond", 1, true) ~= nil, "stat bar labels drawn") and ok
    ok = Assert.greater(#p.rects, 0, "stat bars painted rects") and ok
    return ok
end

tests["weapon_attachment_strip"] = function()
    local scopeTex = getTexture("Item_Scope")
    local item = makeItem({
        getMinDamage = function() return 0 end,
        getMaxDamage = function() return 0 end,
        getCriticalChance = function() return 0 end,
        getActualWeight = function() return 3 end,
    })
    local state = {
        hasAttachments = true,
        attachScope = { getTex = function() return scopeTex end },
    }
    local handled, p = resolve(item, { class = "weapon" }, state)
    local ok = Assert.isTrue(handled, "handled")
    local found = false
    for _, t in ipairs(p.texes) do
        if t:find("Item_Scope", 1, true) then found = true end
    end
    ok = Assert.isTrue(found, "attachment icon drawn in the strip") and ok
    return ok
end

-- ── food ────────────────────────────────────────────────────────────────────

tests["food_cooking_progress_bar"] = function()
    local item = makeItem({
        getFreezingTime = function() return 0 end,
        getMeltingTime = function() return 0 end,
        isBurnt = function() return false end,
    })
    local _, p = resolve(item, { class = "food" }, { cookProgress = 0.5 })
    local ok = Assert.equal(#p.bars, 1, "one progress bar")
    ok = Assert.equal(p.bars[1].fraction, 0.5, "cooking fraction") and ok
    return ok
end

tests["food_burning_progress_bar"] = function()
    local item = makeItem({
        getFreezingTime = function() return 0 end,
        getMeltingTime = function() return 0 end,
        isBurnt = function() return false end,
    })
    local _, p = resolve(item, { class = "food" }, { cookProgress = 1, burnProgress = 0.3 })
    local ok = Assert.equal(#p.bars, 1, "one progress bar")
    ok = Assert.equal(p.bars[1].fraction, 0.3, "burn fraction wins the bar") and ok
    return ok
end

tests["food_freezing_melting_burnt_lines"] = function()
    local freezing = makeItem({ getFreezingTime = function() return 40 end })
    local _, p1 = resolve(freezing, { class = "food" }, { foodState = "frozen" })
    local ok = Assert.isTrue(textsJoined(p1):find("FreezingTime", 1, true) ~= nil, "freezing line")

    local melting = makeItem({
        getFreezingTime = function() return 0 end,
        getMeltingTime = function() return 25 end,
    })
    local _, p2 = resolve(melting, { class = "food" }, { foodState = "frozen" })
    ok = Assert.isTrue(textsJoined(p2):find("MeltingTime", 1, true) ~= nil, "melting line") and ok

    local burnt = makeItem({
        getFreezingTime = function() return 0 end,
        getMeltingTime = function() return 0 end,
        isBurnt = function() return true end,
    })
    local _, p3 = resolve(burnt, { class = "food" }, { foodState = "burnt" })
    ok = Assert.isTrue(textsJoined(p3):find("Burnt", 1, true) ~= nil, "burnt line") and ok
    return ok
end

tests["food_nutrition_when_not_cooking"] = function()
    local item = makeItem({
        getHungerChange = function() return -0.2 end,
        getThirstChange = function() return -0.1 end,
        getCalories = function() return 120 end,
        getActualWeight = function() return 0.3 end,
    })
    -- no cookProgress / frozen / burnt -> cooking provider disabled, nutrition wins
    local handled, p = resolve(item, { class = "food" }, {})
    local ok = Assert.isTrue(handled, "nutrition provider claimed the row")
    local line = textsJoined(p)
    ok = Assert.isTrue(line:find("Hunger: +20", 1, true) ~= nil, "hunger restored rendered") and ok
    ok = Assert.isTrue(line:find("120 kcal", 1, true) ~= nil, "calories rendered") and ok
    return ok
end

tests["dispatch_priority_cooking_beats_nutrition"] = function()
    local item = makeItem({
        getFreezingTime = function() return 0 end,
        getMeltingTime = function() return 0 end,
        isBurnt = function() return false end,
        getHungerChange = function() return -0.2 end,
    })
    local _, p = resolve(item, { class = "food" }, { cookProgress = 0.4 })
    local ok = Assert.equal(#p.bars, 1, "cooking bar drawn")
    ok = Assert.isTrue(textsJoined(p):find("Hunger", 1, true) == nil,
        "nutrition never ran (first enabled provider wins)") and ok
    return ok
end

-- ── clothing / literature ───────────────────────────────────────────────────

tests["clothing_defense_line"] = function()
    local item = makeItem({
        getBiteDefense = function() return 40 end,
        getScratchDefense = function() return 60 end,
        getInsulation = function() return 0.55 end,
        getActualWeight = function() return 1.1 end,
    })
    local handled, p = resolve(item, { class = "clothing" }, {})
    local ok = Assert.isTrue(handled, "clothing provider claimed the row")
    local line = textsJoined(p)
    ok = Assert.isTrue(line:find("Bite: 40", 1, true) ~= nil, "bite defense") and ok
    ok = Assert.isTrue(line:find("Scratch: 60", 1, true) ~= nil, "scratch defense") and ok
    ok = Assert.isTrue(line:find("Insul: 0.6", 1, true) ~= nil, "insulation") and ok
    return ok
end

tests["literature_pages_skill_and_progress"] = function()
    _G.SkillBook = _G.SkillBook or {}
    SkillBook.Carpentry = {
        perk = { getName = function() return "Carpentry" end },
        maxMultiplier2 = 5,
    }
    local item = makeItem({
        getNumberOfPages = function() return 220 end,
        getAlreadyReadPages = function() return 110 end,
        getSkillTrained = function() return "Carpentry" end,
        getLvlSkillTrained = function() return 3 end,
        getMaxLevelTrained = function() return 4 end,
    })
    local handled, p = resolve(item, { class = "literature" }, { pageProgress = 0.5 })
    local ok = Assert.isTrue(handled, "literature provider claimed the row")
    ok = Assert.equal(#p.bars, 1, "partial book renders a progress bar") and ok
    ok = Assert.isTrue(p.bars[1].label:find("Pages: 110 / 220", 1, true) ~= nil, "page count in label") and ok
    ok = Assert.isTrue(p.bars[1].label:find("Carpentry", 1, true) ~= nil, "perk name in label") and ok
    ok = Assert.isTrue(p.bars[1].label:find("x5 XP", 1, true) ~= nil, "tier XP multiplier in label") and ok
    return ok
end

tests["literature_plain_name_fallback"] = function()
    local item = makeItem({
        getNumberOfPages = function() return -1 end,
        getName = function() return "Trashy Novel" end,
    })
    local _, p = resolve(item, { class = "literature" }, {})
    return Assert.isTrue(textsJoined(p):find("Trashy Novel", 1, true) ~= nil,
        "no pages/skill -> plain name line")
end

-- ── container / drainable / fluid / magazine ───────────────────────────────

local function makeContainerInv(items)
    return {
        getItems = function()
            return {
                size = function() return #items end,
                get = function(_, i) return items[i + 1] end,
            }
        end,
    }
end

tests["container_preview_and_overflow"] = function()
    local inner = {}
    for i = 1, 7 do
        inner[i] = makeItem({
            getTex = function() return getTexture("Item_Nails") end,
            getR = function() return 1 end,
            getG = function() return 1 end,
            getB = function() return 1 end,
        })
    end
    local item = makeItem({ getInventory = function() return makeContainerInv(inner) end })
    local handled, p = resolve(item, { class = "container" }, {})
    local ok = Assert.isTrue(handled, "container provider claimed the row")
    ok = Assert.equal(#p.texes, 5, "preview capped at 5 icons") and ok
    ok = Assert.isTrue(textsJoined(p):find("+2", 1, true) ~= nil, "overflow count") and ok
    return ok
end

tests["container_empty_label"] = function()
    local item = makeItem({ getInventory = function() return makeContainerInv({}) end })
    local _, p = resolve(item, { class = "container" }, {})
    return Assert.isTrue(textsJoined(p):find("Empty", 1, true) ~= nil, "empty container labelled")
end

tests["drainable_uses_bar"] = function()
    local item = makeItem({
        getCurrentUsesFloat = function() return 0.75 end,
        getCurrentUses = function() return 3 end,
        getUseDelta = function() return 0.25 end,
    })
    local handled, p = resolve(item, { class = "drainable" }, {})
    local ok = Assert.isTrue(handled, "drainable provider claimed the row")
    ok = Assert.equal(#p.bars, 1, "uses bar drawn")
    ok = Assert.isTrue(p.bars[1].label:find("3 / 4", 1, true) ~= nil, "uses count label") and ok
    ok = Assert.equal(p.bars[1].fraction, 0.75, "bar fraction") and ok
    return ok
end

tests["fluid_level_bar_and_fallback"] = function()
    local item = makeItem({
        getFluidContainer = function()
            return { getAmount = function() return 1.5 end, getCapacity = function() return 2 end }
        end,
    })
    -- class "item": keeps the drainable provider (priority 60, catches
    -- drainable/combo) from claiming the row before the fluid one (65)
    local handled, p = resolve(item, { hasFluid = true, class = "item" }, {})
    local ok = Assert.isTrue(handled, "fluid provider claimed the row")
    ok = Assert.equal(#p.bars, 1, "level bar drawn") and ok
    ok = Assert.isTrue(p.bars[1].label:find("1.5/2.0L", 1, true) ~= nil, "litres label") and ok

    -- fc missing -> classic drainable fallback inside the fluid provider
    local fallback = makeItem({
        getFluidContainer = function() return nil end,
        getCurrentUses = function() return 2 end,
        getUseDelta = function() return 0.5 end,
        getCurrentUsesFloat = function() return 1.0 end,
    })
    local h2, p2 = resolve(fallback, { hasFluid = true, class = "item" }, {})
    ok = Assert.isTrue(h2, "fallback still claims the row") and ok
    ok = Assert.equal(#p2.bars, 1, "fallback bar drawn") and ok
    ok = Assert.isTrue(p2.bars[1].label:find("2/2", 1, true) ~= nil, "fallback uses label") and ok
    return ok
end

tests["magazine_ammo_line"] = function()
    local item = makeItem({
        getMaxAmmo = function() return 30 end,
        getCurrentAmmoCount = function() return 15 end,
    })
    local handled, p = resolve(item, { class = "item" }, {})
    local ok = Assert.isTrue(handled, "magazine provider ran without error")
    ok = Assert.isTrue(textsJoined(p):find("15/30", 1, true) ~= nil, "ammo count rendered") and ok
    return ok
end

return tests
