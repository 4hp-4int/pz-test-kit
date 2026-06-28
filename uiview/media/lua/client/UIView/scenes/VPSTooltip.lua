--[[
    UIView — Scene: a VorpallySauced weapon-mastery tooltip
    =======================================================
    Renders a VPS weapon tooltip headlessly through the REAL TooltipLib
    WorldObjectPanel, using REAL VPS data: affix tables resolved by index
    (getPrefix/getSuffix/getBonding), VPS's own stat label + value formatters
    (VorpallySauced.getStatLabel / formatStatValue) and trait stage colors
    (WeaponTraits.getStageColor).

    Note: VPS's actual provider callback (AddWeaponMasteryInfoCached) reads live
    game state headless mocks don't carry (moodles, weather, kill-velocity
    history), so we drive the same add* sequence here with mock weapon state.
    The CONTENT -- affix names, stat values, tier/stage colors, the stat
    formatting -- is all VorpallySauced's. Only the orchestration is replicated.

    Returns build() -> the WorldObjectPanel.
]]

require "UIView/UIMock"

function isClient() return false end
function isServer() return false end

-- Readable labels without PZ localization: prettify keys, splice format args.
function getText(key, ...)
    if type(key) ~= "string" then return tostring(key) end
    local args = { ... }
    local base = key:gsub("^UI_VorpallySauced_", ""):gsub("^UI_", "")
    base = base:gsub("^Tooltip", ""):gsub("^Prefix_", ""):gsub("^Suffix_", "")
        :gsub("^Bonding_", ""):gsub("^Trait_", ""):gsub("^Mod_", ""):gsub("^Mood_", "")
        :gsub("^Stat_", "")
    base = base:gsub("_", " ")
    if #args > 0 then
        local parts = {}
        for i = 1, #args do parts[i] = tostring(args[i]) end
        base = base .. ": " .. table.concat(parts, " ")
    end
    return base
end

SandboxVars = SandboxVars or {}
SandboxVars.VorpallySauced = SandboxVars.VorpallySauced or {
    EnableMod = true, EnableDebugLogs = false, TraitEffectStrength = 100,
    EnableTraitEffects = true, Tier1Weight = 40, Tier2Weight = 30, Tier3Weight = 20,
    LegendaryChance = 5, BondingKillsMin = 200, BondingKillsMax = 400,
}

require "TooltipLib/Core"
require "TooltipLib/Helpers"
require "TooltipLib/HookWorldObject"

require "VorpallySauced/Core"
require "VorpallySauced/EventBus"
require "VorpallySauced/Events"
require "VorpallySauced/Prefixes"
require "VorpallySauced/Suffixes"
require "VorpallySauced/Bondings"
require "VorpallySauced/AffixRegistry"
require "VorpallySauced/WeaponTraits"

local VPS = _G.VorpallySauced
local Traits = VPS.WeaponTraits

-- VPS color palette (mirrors Tooltips.lua VPS_COLORS)
local C = {
    TRAIT_EFFECT = { 0.62, 0.70, 0.62, 0.9 },
    PROGRESS     = { 0.70, 0.66, 0.86, 1 },
    STAT_LABEL   = { 0.70, 0.70, 0.66, 1 },
    STAT_GREEN   = { 0.55, 0.90, 0.60, 1 },
    STAT_BONDING = { 0.85, 0.55, 0.95, 1 },
    LORE         = { 0.72, 0.66, 0.55, 0.95 },
    PROVENANCE   = { 0.62, 0.80, 0.62, 1 },
}
local TIER_COLOR = {
    [1] = { 0.55, 0.82, 0.98, 1 },   -- Mark (uncommon blue)
    [2] = { 0.70, 0.62, 0.97, 1 },   -- Bond (rare purple)
    blooded = { 0.95, 0.45, 0.55, 1 },
}

-- Replicate VPS addAffixStats: real getStatLabel + formatStatValue per stat.
local function addAffixStats(ctx, affix, valueColor)
    local label = VPS.getStatLabel or function(s) return s end
    local fmt = VPS.formatStatValue or function(_, v) return tostring(v) end
    if affix.stats then
        for stat, value in pairs(affix.stats) do
            ctx:addKeyValue(label(stat), fmt(stat, value), C.STAT_LABEL, valueColor)
        end
    elseif affix.stat then
        ctx:addKeyValue(label(affix.stat), fmt(affix.stat, affix.value), C.STAT_LABEL, valueColor)
    end
end

local function build()
    triggerEvent("OnGameStart")
    local panel = _G.UIView_lastAddedUI
    if not panel then error("WorldObjectPanel not captured") end

    local prefix  = VPS.getPrefix(3)
    local suffix  = VPS.getSuffix(2)
    local bonding = VPS.getBonding(1)

    panel:clearEntries()
    -- Vanilla item-name header (yellowish-white, like ISToolTipInv).
    panel:setTitle("Axe", { 1.0, 1.0, 0.8, 1 })

    local ctx = setmetatable({
        _panel = panel, _itemCount = 0, _needsSeparator = false,
        detail = true, surface = "object", helpers = TooltipLib.Helpers,
    }, { __index = TooltipLib._RecipeContextMT })

    -- ── Vanilla weapon block (HandWeapon.DoTooltip order for a Fire Axe) ──
    -- name (above), sharpness, handle+head condition, damage, two-hand, weight.
    -- Condition/sharpness shown worn, as a 263-kill axe would be. Bars use PZ's
    -- bad->good (red->green) gradient by fraction; labels are yellowish-white.
    local YELLOW, WHITE = { 1.0, 1.0, 0.8, 1 }, { 1.0, 1.0, 1.0, 1 }
    local function barColor(frac)
        local t = math.max(0, math.min(1, frac))
        return { 0.8 + (0.3 - 0.8) * t, 0.3 + (1.0 - 0.3) * t, 0.2 + (0.2 - 0.2) * t, 1 }
    end
    ctx:addProgress("Sharpness", 0.62, YELLOW, barColor(0.62))
    ctx:addProgress("Handle Condition", 0.77, YELLOW, barColor(0.77))
    ctx:addProgress("Head Condition", 0.69, YELLOW, barColor(0.69))
    ctx:addProgress("Damage", 0.56, YELLOW, barColor(0.56))
    ctx:addLabel("Two-Hand Weapon", YELLOW)
    ctx:addKeyValue("Weight", "3.0", YELLOW, WHITE)
    ctx:addDivider({ 0.4, 0.4, 0.4, 0.5 })

    -- ── VorpallySauced mastery block (appended below vanilla, as in game) ──
    -- Trait line: primary (stage color) + modifier + mood, as VPS draws it.
    local stageColor = (Traits and Traits.getStageColor and Traits.getStageColor("Proven"))
        or { 0.45, 0.85, 0.80, 1 }
    ctx:addLabel("Proven. Nocturnal. Hunting.", stageColor)
    ctx:addLabel("  Strikes harder after dark.", C.TRAIT_EFFECT)
    ctx:addLabel("The axe is stirring, eager.", C.PROGRESS)

    if prefix then
        ctx:addHeader(getText("UI_VorpallySauced_TooltipMark", getText(prefix.name)),
            TIER_COLOR[prefix.tier] or TIER_COLOR[1], true)
        addAffixStats(ctx, prefix, C.STAT_GREEN)
    end
    if suffix then
        ctx:addHeader(getText("UI_VorpallySauced_TooltipBond", getText(suffix.name)),
            TIER_COLOR[suffix.tier] or TIER_COLOR[2], true)
        addAffixStats(ctx, suffix, C.STAT_GREEN)
    end
    if bonding then
        ctx:addHeader(getText("UI_VorpallySauced_TooltipBlooded", getText(bonding.name)),
            TIER_COLOR.blooded, true)
        ctx:addText("\"It remembers every kill, and asks for more.\"", C.LORE)
        addAffixStats(ctx, bonding, C.STAT_BONDING)
    end

    ctx:addLabel("Blooded -- reforging is safe.", C.PROVENANCE)

    local w = panel:measureWidth(220)
    panel:setWidth(w)
    panel:setX(24); panel:setY(24)
    panel:setVisible(true)
    return panel
end

return { build = build }
