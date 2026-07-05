--[[
    SauceTooltips WeaponStats provider — the raw combat-stat card
    =============================================================
    Drives the REAL registered provider callback over a mock HandWeapon
    (public getters only) and locks: it registers on TooltipLib, base rows
    always show, detail-only rows appear ONLY under ctx.detail, gun items
    take the firearm branch, tree/head rows gate on their getters, and the
    tree-break divisor keys on the CHOP_TREE tag (the workflow-verified fix,
    not the Axe weapon category).
]]

local Assert = PZTestKit.Assert
require "UIView/UIMock"
require "TooltipLib/Core"
require "TooltipLib/Helpers"

-- globals the provider reads (harness has TooltipLib real; stub the rest)
_G.getText = function(k, a) if a ~= nil then return k .. "|" .. tostring(a) end return k end
_G.isServer = _G.isServer or function() return false end
_G.isClient = _G.isClient or function() return true end
_G.ItemTag = _G.ItemTag or { CHOP_TREE = "CHOP_TREE" }
local _player = { getMaintenanceMod = function() return 3 end }
_G.getPlayer = function() return _player end

require "SauceTooltips/WeaponStats"

-- the registered provider WITH its callback (getProviders() returns a
-- metadata-only view; the callback lives in the internal registry)
local function weaponProvider()
    return TooltipLib._providers and TooltipLib._providers["SauceTooltips_WeaponStats"]
end

-- recording ctx: captures every row's label+value so we can assert content
local function recCtx(detail, item)
    local c = { detail = detail, item = item, rows = {}, sections = {} }
    function c:addKeyValue(label, value) self.rows[#self.rows + 1] = { label = label, value = tostring(value) } end
    function c:addLabel(text) self.rows[#self.rows + 1] = { label = text } end
    function c:addProgress(label) self.rows[#self.rows + 1] = { label = label } end
    function c:beginSection(label) self.sections[#self.sections + 1] = label end
    return c
end

local function has(ctx, labelKey)
    for _, r in ipairs(ctx.rows) do if r.label == labelKey then return r end end
    return nil
end

-- a mock melee HandWeapon: only the getters the provider touches
local function meleeWeapon(over)
    local w = {
        _tags = {}, _treeDmg = 0, _head = false,
        getMinDamage = function() return 0.8 end,
        getMaxDamage = function() return 1.9 end,
        getCriticalChance = function() return 20 end,
        getCriticalDamageMultiplier = function() return 3.0 end,
        getDamageMod = function() return 1.4 end,
        getMaxRange = function() return 1.23 end,
        getMinRange = function() return 0.61 end,
        getRangeMod = function() return 1.0 end,
        getBaseSpeed = function() return 0.95 end,
        getConditionLowerChance = function() return 13 end,
        getEnduranceMod = function() return 1.0 end,
        isUseEndurance = function() return true end,
        getEffectiveWeight = function() return 2.0 end,
        getMaxHitCount = function() return 2 end,
        getTreeDamage = function() return 0 end,
        isRanged = function() return false end,
        hasHeadCondition = function() return false end,
        getHittingMod = function() return 1.0 end,
    }
    w.getScriptItem = function() return { containsWeaponCategory = function() return false end } end
    w.hasTag = function(self, t) return w._tags[t] == true end
    if over then for k, v in pairs(over) do w[k] = v end end
    -- default any unmocked getter to a 0-returning function (the provider
    -- pcall-guards optional getters; this stops a missing one from throwing)
    return setmetatable(w, { __index = function() return function() return 0 end end })
end

local tests = {}

tests["provider_registers"] = function()
    local p = weaponProvider()
    return Assert.notNil(p, "SauceTooltips_WeaponStats registered on TooltipLib")
        and Assert.equal(p.target, "item", "item surface")
        and Assert.notNil(p.description, "has a description key (gets a TooltipLib toggle)")
end

tests["base_rows_always_detail_rows_gated"] = function()
    local p = weaponProvider()
    local item = meleeWeapon()
    local base = recCtx(false, item)
    p.callback(base)
    local ok = Assert.notNil(has(base, "UI_ST_Damage"), "damage row always shows")
        and Assert.notNil(has(base, "UI_ST_CritChance"), "crit chance always shows")
        and Assert.isTrue(has(base, "UI_ST_SkillDamage") == nil, "skill-effective damage is detail-only (hidden)")
        and Assert.isTrue(has(base, "UI_ST_CritDamage") == nil, "crit damage is detail-only (hidden)")

    local det = recCtx(true, item)
    p.callback(det)
    ok = Assert.notNil(has(det, "UI_ST_SkillDamage"), "skill-effective damage appears under detail") and ok
    ok = Assert.notNil(has(det, "UI_ST_CritDamage"), "crit damage appears under detail") and ok
    return ok
end

tests["damage_value_is_the_raw_min_max"] = function()
    local p = weaponProvider()
    local ctx = recCtx(false, meleeWeapon())
    p.callback(ctx)
    local r = has(ctx, "UI_ST_Damage")
    return Assert.isTrue(r ~= nil and r.value:find("0.80", 1, true) ~= nil
        and r.value:find("1.90", 1, true) ~= nil,
        "damage shows the raw min-max numbers (0.80 - 1.90), not a bar")
end

tests["tree_break_keys_on_chop_tree_tag"] = function()
    local p = weaponProvider()
    -- a tree-chopper: CHOP_TREE tag set → x2 durability divisor
    local axe = meleeWeapon({ getTreeDamage = function() return 35 end })
    axe._tags["CHOP_TREE"] = true
    local ctx = recCtx(true, axe)
    p.callback(ctx)
    -- clc(13)*2 + maint(3) = 29  → "1 / 29"
    local r = has(ctx, "UI_ST_TreeBreak")
    return Assert.isTrue(r ~= nil and r.value:find("29", 1, true) ~= nil,
        "tree-break uses the CHOP_TREE x2 divisor (1 in 29), not the Axe category")
end

tests["firearm_takes_the_gun_branch"] = function()
    local p = weaponProvider()
    local gun = meleeWeapon({
        isRanged = function() return true end,
        getHitChance = function() return 45 end,
        getRecoilDelay = function() return 20 end,
        getAimingTime = function() return 20 end,
        getMaxRange = function() return 7 end,
        getClipSize = function() return 15 end,
        getJamGunChance = function() return 1.5 end,
        getAimingPerkHitChanceModifier = function() return 2 end,
        getWeaponReloadType = function() return { toString = function() return "M9" end } end,
    })
    local ctx = recCtx(false, gun)
    p.callback(ctx)
    return Assert.notNil(has(ctx, "UI_ST_HitChance"), "gun shows hit chance")
        and Assert.isTrue(has(ctx, "UI_ST_BreakChance") == nil, "melee-only break row absent on a gun")
end

return tests
