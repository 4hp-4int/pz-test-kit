--[[
    UIView — the journal's three surfaces, side by side

    MOUNTS THE MOD'S OWN COMPONENTS. Every page here comes from
    VorpallySauced.Components; this file supplies fixtures and a host panel and
    nothing else. The older VPS scenes each reimplement the nine-patch draw
    locally, which is why they drifted from the mod they were meant to preview
    -- there is nothing to drift from here, because there is only one
    definition.

    Three surfaces, because judging them apart is how you end up with three
    pages that each look fine and do not belong to the same book.
]]

require "UIView/UIMock"
require "VorpallySauced/Prefixes"
require "VorpallySauced/Suffixes"
require "VorpallySauced/FirearmPrefixes"
require "VorpallySauced/FirearmSuffixes"
require "VorpallySauced/Bondings"
require "VorpallySauced/CompendiumData"
require "VorpallySauced/Knowledge"
require "VorpallySauced/Tally"
require "VorpallySauced/Layout"
require "VorpallySauced/Chrome"
require "VorpallySauced/Provenance"
require "VorpallySauced/Components"

local fm = UIView_fontMetrics
local K  = VorpallySauced.Knowledge
local L  = VorpallySauced.Layout
local C  = VorpallySauced.Components
local Tally = VorpallySauced.Tally

L.setMeasurer(function(font, text)
    local m = fm(font)
    return math.floor(#tostring(text) * m.w + 0.5), m.h
end)

local Pages = {}

local PAGE_W, PAGE_H = 560, 700
local GAP = 18
local W = PAGE_W * 4 + GAP * 5
local H = PAGE_H + GAP * 2

local FONTS = { title = UIFont.Medium, subtitle = UIFont.Medium }

-- ── fixtures ───────────────────────────────────────────────────────────────
-- Deliberately the MESSY MIDDLE. A fully-explored save and an empty one both
-- render fine, which is exactly why neither tells you whether the states are
-- distinguishable.

local function fixtureLog()
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
    }
end

local function withFixture(fn)
    local saved = VorpallySauced.DiscoveryLog
    local log = fixtureLog()
    VorpallySauced.DiscoveryLog = { getDiscoveries = function() return log end }
    K.invalidate()
    local a, b = fn()
    VorpallySauced.DiscoveryLog = saved
    K.invalidate()
    return a, b
end

local BONDS = {
    { name = "Kitchen Knife", kills = 143, lost = true,  icon = "Item_KitchenKnife_Forged" },
    { name = "Machete",       kills = 402, lost = true,  icon = "Item_Machete",
      isReforged = true, reforgeKills = 143 },
    { name = "Fire Axe",      kills = 812, icon = "Item_Fireaxe_Head",
      character = "Patient trait, Gorged mood",
      isReforged = true, reforgeKills = 545 },
    { name = "Hunting Rifle", kills = 61,  icon = "Item_HuntingRifle" },
    { name = "Crowbar",       kills = 7, lost = true, icon = "Item_Crowbar" },
}

-- ── host ───────────────────────────────────────────────────────────────────

local Page = ISPanel:derive("VPSJournalPages")

function Page:new(x, y, w, h)
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    return o
end

function Page:prerender()
    ISPanel.prerender(self)

    local sections, summary = withFixture(function()
        return K.sections(nil), select(2, K.index(nil))
    end)

    -- The two lists and the two DRILLDOWNS they open, side by side, because a
    -- list and its detail page have to look like the same book.
    local volSection
    for _, sec in ipairs(sections) do
        if sec.isStudied then volSection = sec break end
    end

    local volRows = {}
    if volSection then
        for i, r in ipairs(volSection.rows) do
            if i > 5 then break end
            local row = {}
            for k, v in pairs(r) do row[k] = v end
            row.valueText = "+12% crit"
            volRows[#volRows + 1] = row
        end
    end

    local LORE = "I don't know who's gonna read this. Maybe nobody. But someone's gotta write it down before we all forget what's real and what ain't. It started maybe a week after the blockade. Tommy Culver's hatchet."

    local pages = {
        C.IndexPage({
            sections = sections, summary = summary,
            width = PAGE_W, fonts = FONTS,
        }),
        C.VolumePage({
            volume = volSection and volSection.volume or nil,
            isStudied = true,
            titleText = "The Stir",
            intro = LORE,
            rows = volRows,
            unmeasuredText = "unmeasured",
            width = PAGE_W,
            progressText = volSection and ("%d / %d met"):format(
                volSection.witnessed, volSection.total) or "",
            fonts = FONTS,
        }),
        C.MemorialPage({ bonds = BONDS, cap = 32, fonts = FONTS }),
        C.BondPage({
            bond = BONDS[3],
            -- Provenance as it renders once SauceTooltips is installed. Absent
            -- entries are the honest case when no street was close enough.
            marks = {
                { label = "Mark",    name = "Undying-Wrought",  place = "near Cortman Medical" },
                { label = "Bond",    name = "of the Red Feast", place = "on West Point Road" },
                { label = "Blooded", name = "Keen" },
            },
            fonts = FONTS,
        }),
    }

    local collisions = 0
    for i, page in ipairs(pages) do
        local shell = C.Shell({ children = { page } })
        L.render(self, shell, GAP + (i - 1) * (PAGE_W + GAP), GAP, PAGE_W, PAGE_H)
        collisions = collisions + #L.overlaps(shell)

        -- The preview has no ISRichTextPanel, so it draws what the host will
        -- put in the slot: the reserved box, and the lore wrapped inside it.
        -- Showing the RESERVATION is the point -- an empty slot on this page
        -- would look like the lore had gone missing.
        local slot = L.slots(shell).lore
        if slot then
            self:drawRect(slot.x, slot.y, slot.w, slot.h, 0.05, 0, 0, 0)
            self:drawRectBorder(slot.x, slot.y, slot.w, slot.h, 0.15, 0, 0, 0)
            local para = L.paragraph(LORE, { width = slot.w - 12, color = C.FAINT })
            L.render(self, para, slot.x + 6, slot.y + 5, slot.w - 12, slot.h - 10)
        end
    end

    -- The guard a hand-positioned page could not have. Says it here rather
    -- than waiting for someone to spot it on a screenshot.
    if collisions > 0 then
        self:drawText("LAYOUT COLLISIONS: " .. collisions, GAP, H - 18,
                      1, 0.3, 0.3, 1, UIFont.Small)
    end
end

function Pages.build()
    local p = Page:new(0, 0, W, H)
    p:initialise()
    return p
end

Pages.W, Pages.H = W, H
return Pages
