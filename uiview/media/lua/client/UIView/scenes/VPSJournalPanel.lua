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

-- THE PANEL SIZES ITSELF, so the scene must ask rather than assume.
--
-- The book's page width now follows the player's font size (a 400px page is
-- only a readable measure at PZ's 1x type), so a hardcoded 910 here silently
-- cropped the right-hand page off every preview the moment the panel grew.
-- The grid is laid out from the real size instead.
local GAP = 18
local PANEL_W, PANEL_H, W, H

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
      -- LEGENDARY, THREE STATS EACH. Vampiric (crit / crit damage / speed) and
      -- of the Eternal. This is the shape that used to be joined into one
      -- pipe-separated line and shoved onto the name row; a fixture that only
      -- carried single-stat affixes previewed the easy case forever.
      -- The ids the trait block needs. A fixture carrying only the RENDERED
      -- character string previews the page as it looked before the effect was
      -- reachable, which is the state this is meant to catch.
      characterPrimary = "Seasoned", characterModifier = "HordeBreaker",
      prefixId = 34, suffixId = 31, bondingThreshold = 900,
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
        -- 34 and 37 are legendary (three stats each), so the volume page has
        -- both a witnessed multi-stat entry and unwitnessed neighbours.
        discoveredPrefixes = { ["1"] = true, ["4"] = true, ["11"] = true,
                               ["34"] = true, ["37"] = true },
        discoveredSuffixes = { ["2"] = true, ["9"] = true, ["31"] = true },
        discoveredBondings = { ["3"] = true },
        discoveredFirearmPrefixes = {},
        discoveredFirearmSuffixes = { ["5"] = true },
        discoveredFirearmBondings = {},
        studiedVolumes = {
            ["VorpallySauced.CompendiumAwakening"] = true,
            ["VorpallySauced.CompendiumBondedWeapon"] = true,
            -- Vol. IV documents the legendaries.
            ["VorpallySauced.CompendiumLegendsOfBlade"] = true,
        },
        weaponBonds = BONDS,
        -- the Stir (STIR_JOURNAL.md): a few effects seen in offers, a few carried,
        -- across all four families, so every state shows on THE STIR's spread
        stirStudied = { calm = true, stagger = true, decoy = true, nextcrit = true, rangebuff = true },
        stirWitnessed = { dmgbuff = { hour = 120 }, breath = { hour = 300 }, ignite = { hour = 410 },
                          unseen = { hour = 512 }, critbuff = { hour = 600 } },
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

local function panelAt(x, y, configure)
    local JournalPanel = VorpallySauced.FieldJournalPanel
    local p = JournalPanel:new(x, y, fixturePlayer())
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

--- Measure one panel, then size the grid to it.
local function measurePanel()
    local probe = VorpallySauced.FieldJournalPanel:new(0, 0, fixturePlayer())
    PANEL_W, PANEL_H = probe.width, probe.height
    W = PANEL_W * 2 + GAP * 3
    H = PANEL_H * 3 + GAP * 4
    Scene.W, Scene.H = W, H
end

function Scene.build()
    installFixtures()
    -- the Stir on in this world, the zombie-chance family switched off (the page marks it)
    SandboxVars.VorpallySauced = SandboxVars.VorpallySauced or {}
    SandboxVars.VorpallySauced.EnableGenome = true
    SandboxVars.VorpallySauced.StirZombieChance = false
    require "VorpallySauced/Genome/Families"
    require "VorpallySauced/Genome/Program"
    require "VorpallySauced/Genome/Words"
    -- the first weapon has stirred: two effects (its copy, packed as the game
    -- packs it), Seasoned, and a timeline that shows every kind of row
    local Program = VorpallySauced.Genome.Program
    BONDS[1].stir = Program.packClient({
        { ev = "kill", act = { id = "breath", amt = 6 } },
        { ev = "hit", act = { id = "stagger", amt = 20 } },
    }, 1.3, 3)
    BONDS[1].stirStage = "Seasoned"
    BONDS[1].stirLog = {
        { k = "born", a = "breath", kills = 214, place = { street = "Cortman Drive", band = "on" }, hour = 120 },
        { k = "kept", kills = 388, hour = 300 },
        { k = "new", a = "stagger", kills = 506, place = { street = "Main Street", band = "near" }, hour = 410 },
        { k = "stronger", a = "breath", kills = 731, hour = 600 },
    }
    measurePanel()

    local host = Host:new(W, H)
    host:initialise()

    local sections = VorpallySauced.Knowledge.sections(nil)
    -- PREFER A VOLUME WITH MULTI-STAT ENTRIES. Picking the first studied book
    -- meant previewing Vol. I forever -- every one of its entries is a single
    -- stat on one line, which is the case that was never in doubt.
    -- Highest PROPORTION of multi-stat entries, not merely "has one": Vol. I
    -- turns out to carry a single multi-stat tier-1 affix among its twelve, so
    -- "any" picked it and previewed eleven single-stat rows again. Vol. IV is
    -- 7 of 7, which is the page that actually exercises the stacked form.
    local studied, best = nil, -1
    for _, sec in ipairs(sections) do
        if sec.isStudied and #sec.rows > 0 then
            local multi = 0
            for _, r in ipairs(sec.rows) do
                if r.affix and r.affix.stats then multi = multi + 1 end
            end
            local ratio = multi / #sec.rows
            if ratio > best then studied, best = sec.source, ratio end
        end
    end

    local views = {
        function(p) end,                                    -- the index
        function(p) p.openVolume = studied; p:refresh() end, -- a volume, reread
        function(p) p.activeTab = 2; p:refresh() end,        -- the ones before
        function(p) p.openBond = BONDS[1]; p:refresh() end,  -- one weapon
        -- The reference tab. Its content is the same on every save, which is
        -- exactly why it needs looking at: nothing in a fixture can make it
        -- wrong, and nothing in play will make anyone notice if it is.
        function(p) p.activeTab = 3; p:refresh() end,        -- character
        function(p) p.openStir = true; p:refresh() end,       -- THE STIR (STIR_JOURNAL.md 4.1)
    }

    -- Two across: a spread is too wide for one row.
    for i, cfg in ipairs(views) do
        local col = (i - 1) % 2
        local row = math.floor((i - 1) / 2)
        host:addChild(panelAt(GAP + col * (PANEL_W + GAP),
                              GAP + row * (PANEL_H + GAP), cfg))
    end
    return host
end

-- Provisional until build() measures a real panel; the harness reads these
-- before it renders, and a nil here is a crash rather than a wrong number.
Scene.W, Scene.H = 910 * 2 + GAP * 3, 668 * 3 + GAP * 4
return Scene
