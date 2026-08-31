--[[
    UIView — the REAL Field Journal panel, all four views

    NOT the pages. THE PANEL. VPSJournalPages mounts the page components on a
    bare card, which is genuinely useful for judging a page's typography and
    caught real overflow bugs -- but it shows only the middle of the window. It
    has no tabs, no Back/Close/Clear buttons, no scroll bar, and no panel shell,
    so every one of those shipped unreviewed. The first in-game screenshot came
    back with "I see buttons which aren't rendered in the ui mocks", which is
    exactly right and exactly the gap.

    This mounts VorpallySauced.FieldJournalPanel itself -- the same class
    openFieldJournal() constructs -- against UIMock's ISPanel/ISButton/ISLabel
    and a fixture DiscoveryLog. What renders here is what the game renders,
    including the chrome dressing on every widget.

    Four instances so the states can be judged together: a panel that looks
    right on the index and wrong on a drilldown is not "mostly right".
]]

require "UIView/UIMock"
require "VorpallySauced/Prefixes"
require "VorpallySauced/Suffixes"
require "VorpallySauced/FirearmPrefixes"
require "VorpallySauced/FirearmSuffixes"
require "VorpallySauced/Bondings"
require "VorpallySauced/CompendiumData"
require "VorpallySauced/Knowledge"
-- Required HERE, at file scope, not inside build(): requiring it pulls in the
-- real DiscoveryLog, which would overwrite the fixture if the fixture were
-- installed first. Load everything, then swap.
require "VorpallySauced/FieldJournalUI"

local Scene = {}

local PANEL_W, PANEL_H = 560, 700
local GAP = 18
local W = PANEL_W * 4 + GAP * 5
local H = PANEL_H + GAP * 2

-- ── fixtures ───────────────────────────────────────────────────────────────
-- The messy middle again: some volumes studied, some untouched, bonds both
-- carried and lost. A full save and an empty one both render fine, which is
-- why neither tells you whether the states are distinguishable.

local BONDS = {
    { weaponId = 501, name = "Fire Axe", kills = 812, isFirearm = false,
      fullType = "Base.Axe", character = "Patient trait, Gorged mood",
      isReforged = true, reforgeKills = 545,
      -- Marked and Bonded but NOT yet Blooded, so the page has something left
      -- to count toward and the tally renders. A fully Blooded weapon draws
      -- none, which is correct and also shows nothing -- a fixture that picks
      -- the finished case previews the empty state forever.
      prefixId = 1, suffixId = 2, bondingThreshold = 900,
      places = { prefix = { street = "Cortman Drive", band = "near" },
                 suffix = { street = "West Point Road", band = "on" } } },
    { weaponId = 502, name = "Hunting Rifle", kills = 61, isFirearm = true,
      fullType = "Base.HuntingRifle", prefixId = 1 },
    { weaponId = 503, name = "Machete", kills = 402, lost = true,
      fullType = "Base.Machete", isReforged = true, reforgeKills = 143,
      prefixId = 4, suffixId = 9 },
    { weaponId = 504, name = "Kitchen Knife", kills = 143, lost = true,
      fullType = "Base.KitchenKnife" },
    { weaponId = 505, name = "Crowbar", kills = 7, lost = true,
      fullType = "Base.Crowbar" },
}

local function discoveries()
    return {
        discoveredPrefixes = { ["1"] = true, ["4"] = true, ["11"] = true },
        discoveredSuffixes = { ["2"] = true, ["9"] = true },
        discoveredBondings = { ["3"] = true },
        discoveredFirearmPrefixes = {},
        discoveredFirearmSuffixes = { ["5"] = true },
        discoveredFirearmBondings = {},
        studiedVolumes = {
            ["VorpallySauced.CompendiumAwakening"] = true,
            ["VorpallySauced.CompendiumBondedWeapon"] = true,
        },
        weaponBonds = BONDS,
    }
end

local function installFixtures()
    local disc = discoveries()
    VorpallySauced.DiscoveryLog = {
        getDiscoveries = function() return disc end,
        getBondRegistry = function() return disc.weaponBonds end,
        getJournalCondition = function()
            return getText("UI_VorpallySauced_JournalCondition_20")
        end,
        clearLostBonds = function() end,
        recordBondPlace = function() return false end,
    }
    VorpallySauced.Knowledge.invalidate()

    -- Item icons come through ScriptManager; without it every row previews
    -- without its weapon, which is one of the things the memorial is for.
    if not _G.getScriptManager then
        _G.getScriptManager = function()
            return {
                getItem = function(_, fullType)
                    local icon = ({
                        ["Base.Axe"] = "Item_Fireaxe_Head",
                        ["Base.HuntingRifle"] = "Item_HuntingRifle",
                        ["Base.Machete"] = "Item_Machete",
                        ["Base.KitchenKnife"] = "Item_KitchenKnife_Forged",
                        ["Base.Crowbar"] = "Item_Crowbar",
                    })[fullType]
                    if not icon then return nil end
                    return { getNormalTexture = function()
                        return { getName = function() return icon end }
                    end }
                end,
            }
        end
    end
    if not _G.getPlayer then _G.getPlayer = function() return nil end end
end

--- The panel needs a player only as an opaque key into the fixture log.
local function fixturePlayer()
    return {
        getInventory = function() return nil end,
        getPrimaryHandItem = function() return nil end,
        transmitModData = function() end,
    }
end

-- ── mounting ───────────────────────────────────────────────────────────────

local function panelAt(x, configure)
    local JournalPanel = VorpallySauced.FieldJournalPanel
    local p = JournalPanel:new(x, GAP, fixturePlayer())
    p:initialise()
    -- instantiate() builds the children, exactly as vanilla does. Calling
    -- createChildren() as well would build the whole panel twice -- which it
    -- did, and showed up as three tab rows stacked on one another.
    p:instantiate()
    if configure then configure(p) end
    return p
end

local Host = ISPanel:derive("VPSJournalPanelHost")

function Host:new(w, h)
    local o = ISPanel:new(0, 0, w, h)
    setmetatable(o, self)
    self.__index = self
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    return o
end

function Scene.build()
    installFixtures()

    local host = Host:new(W, H)
    host:initialise()

    local sections = VorpallySauced.Knowledge.sections(nil)
    local studied
    for _, sec in ipairs(sections) do
        if sec.isStudied then studied = sec.source break end
    end

    local views = {
        function(p) end,                                    -- the index
        function(p) p.openVolume = studied; p:refresh() end, -- a volume, reread
        function(p) p.activeTab = 2; p:refresh() end,        -- the ones before
        function(p) p.openBond = BONDS[1]; p:refresh() end,  -- one weapon
    }

    for i, cfg in ipairs(views) do
        host:addChild(panelAt(GAP + (i - 1) * (PANEL_W + GAP), cfg))
    end
    return host
end

Scene.W, Scene.H = W, H
return Scene
