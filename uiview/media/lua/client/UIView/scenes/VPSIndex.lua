--[[
    UIView — Morrison's Field Journal, THE INDEX
    ============================================
    Renders the REAL modules, not a mockup: VorpallySauced.Knowledge decides
    what the player knows and VorpallySauced.Chrome paints it. The older VPS
    scenes here are self-contained concept pieces that reimplement `nine`
    locally; this one is a preview of the shipping code, so a change to either
    module shows up here without anyone porting it.

    The page is a back-of-book index. Three states:

      witnessed   inked, with values      you have held one
      studied     named, values blank     a volume you read documents it
      unknown     a blank rule            neither -- but the rule keeps its
                                          ALPHABETICAL SEAT, so a gap between
                                          two names you know says "there is
                                          something here you have not met"

    The synthetic log below is deliberately partial: a couple of volumes read,
    a handful of affixes actually met. A fully-known index and a fully-unknown
    one both look fine, which is exactly why the interesting preview is the
    messy middle.
]]

require "UIView/UIMock"
require "VorpallySauced/Prefixes"
require "VorpallySauced/Suffixes"
require "VorpallySauced/FirearmPrefixes"
require "VorpallySauced/FirearmSuffixes"
require "VorpallySauced/Bondings"
require "VorpallySauced/CompendiumData"
require "VorpallySauced/Knowledge"
require "VorpallySauced/Chrome"
require "VorpallySauced/Layout"

local fm = UIView_fontMetrics
local K = VorpallySauced.Knowledge
local Chrome = VorpallySauced.Chrome
local L = VorpallySauced.Layout

-- The harness owns text metrics; the engine asks rather than assumes.
L.setMeasurer(function(font, text)
    local m = fm(font)
    return math.floor(#tostring(text) * m.w + 0.5), m.h
end)

local VPSIndex = {}

local W, H = 620, 760
local PAD = 22

local CREAM = { 0.88, 0.84, 0.76 }
local INK   = { 0.20, 0.17, 0.13 }
local MUTED = { 0.46, 0.42, 0.36 }
local FAINT = { 0.62, 0.58, 0.50 }
local TEAL  = { 0.18, 0.46, 0.41 }

local function fh(font) return fm(font).h end
local function fw(font, s) return math.floor(#tostring(s) * fm(font).w + 0.5) end

--- A partially-explored player: two volumes read, a few affixes met.
local function fixtureLog()
    return {
        discoveredPrefixes = { ["1"] = true, ["4"] = true, ["11"] = true },
        discoveredSuffixes = { ["2"] = true, ["9"] = true },
        discoveredBondings = { ["3"] = true },
        discoveredFirearmPrefixes = {},
        discoveredFirearmSuffixes = { ["5"] = true },
        discoveredFirearmBondings = {},
        studiedVolumes = {
            ["VorpallySauced.CompendiumAwakening"] = true,     -- tier-1 melee marks
            ["VorpallySauced.CompendiumBondedWeapon"] = true,  -- all melee bonds
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

local Page = ISPanel:derive("VPSIndexPage")

function Page:new(x, y, w, h)
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    return o
end

function Page:renderRow(row, x, y, colW)
    local h = fh(UIFont.Small)

    if row.state == K.UNKNOWN then
        -- A blank rule, not a name and not "???". Short, so the eye reads it
        -- as an absence rather than a redaction.
        -- Short and faint on purpose. At 42% width and 0.30 alpha these read
        -- as a row of dashes louder than the names between them -- absence
        -- should be quieter than presence, not the loudest thing on the page.
        local ruleW = math.floor(colW * 0.22)
        self:drawRect(x, y + math.floor(h * 0.62), ruleW, 1,
                      0.16, FAINT[1], FAINT[2], FAINT[3])
        return
    end

    local name = K.displayName(row) or "?"
    local c = (row.state == K.WITNESSED) and INK or MUTED
    self:drawText(name, x, y, c[1], c[2], c[3], 1, UIFont.Small)

    -- Witnessed entries have earned their numbers; studied ones are named but
    -- blank on value, which is the whole reason to go looking for one.
    if row.showValues and row.affix then
        local v = row.affix.value
        if v then
            local s = (v < 1 and v > 0) and ("+" .. math.floor(v * 100 + 0.5) .. "%")
                       or ("+" .. tostring(v))
            self:drawText(s, x + colW - fw(UIFont.Small, s) - 6, y,
                          TEAL[1], TEAL[2], TEAL[3], 1, UIFont.Small)
        end
    end
end

--- "Marks" / "Bonds" / "Blooded", and which side of the mod they belong to.
local SLOT_LABEL = { prefix = "MARKS", suffix = "BONDS", bonding = "BLOODED" }

--- The section is one VOLUME, so its title is that book's subject.
local function sectionTitle(sec)
    local vol = sec.volume
    if not vol then return "OTHER" end
    local base = SLOT_LABEL[vol.affixType] or string.upper(tostring(vol.affixType))
    if vol.type == "firearm" then base = "FIREARM " .. base end
    return base
end

--- One volume row, as a TREE. No coordinates anywhere: the label column is
--- measured, the title follows it, and the spacer pushes the count to the
--- right edge. The "Vol. VIIIBLOODED" collision is not fixed here, it is
--- unrepresentable.
local function volumeRow(sec, meterW)
    local vol = sec.volume
    local ink = sec.collapsed and FAINT or INK

    local note
    if sec.collapsed then
        note = "unread"
    elseif sec.isStudied and sec.witnessed == sec.total then
        note = "complete"
    elseif sec.isStudied then
        note = ("studied - %d met in the field"):format(sec.witnessed)
    else
        note = ("%d met in the field, unread"):format(sec.witnessed)
    end

    local known = sec.total > 0 and math.floor(meterW * sec.known / sec.total + 0.5) or 0
    local seen  = sec.total > 0 and math.floor(meterW * sec.witnessed / sec.total + 0.5) or 0

    return L.col({ gap = 3 },
        L.row({ gap = 14 },
            L.text(vol and ("Vol. " .. vol.volumeNum) or "", { color = MUTED, minW = 0 }),
            L.text(sectionTitle(sec), { color = ink }),
            L.spacer(),
            L.text(("%d / %d"):format(sec.known, sec.total), { color = MUTED })),
        -- Meter as a stack: track, then what is known, then what has actually
        -- been met. Scaled to the BOOK'S own size so eight lopsided volumes
        -- stay comparable at a glance.
        L.stack({},
            L.rect({ h = 3, w = meterW, color = { INK[1], INK[2], INK[3], 0.10 } }),
            L.rect({ h = 3, w = known,  color = { INK[1], INK[2], INK[3], 0.30 } }),
            L.rect({ h = 3, w = seen,   color = { TEAL[1], TEAL[2], TEAL[3], 0.85 } })),
        L.text(note, { color = FAINT }))
end

--- The whole page, as one tree. There is not a single coordinate below this
--- line: the card insets its own content, the spacer finds the right edge, and
--- every column is measured. That is the entire reason this layer exists.
function Page:prerender()
    ISPanel.prerender(self)

    local sections, summary = withFixture(function()
        return K.sections(nil), select(2, K.index(nil))
    end)

    local cardInset = Chrome.inset("lite_card") or 14
    local meterW = self.width - PAD * 2 - cardInset * 2 - 20 - 120

    local rows = {}
    for _, sec in ipairs(sections) do rows[#rows + 1] = volumeRow(sec, meterW) end

    -- Named parts rather than one deep literal. A tree written as five nested
    -- constructors is as unreadable as the arithmetic it replaced, and the
    -- first attempt at exactly that would not even compile.
    local header = L.row({},
        L.text("THE INDEX", { font = UIFont.Medium, color = INK }),
        L.spacer(),
        L.text(("%d of %d met"):format(summary.witnessed, summary.total),
               { color = MUTED }))

    local body = L.col({ gap = 12, pad = 10, fill = true },
        header,
        L.col({ gap = 12 }, unpack(rows)))

    local card = L.nine("lite_card", {
        inset = cardInset, fill = true, children = { body },
    })

    local page = L.nine("lite_panel", {
        inset = Chrome.inset("lite_panel") or 20, children = { card },
    })

    L.render(self, page, 0, 0, self.width, self.height)

    -- The guard the hand-positioned version could not have: if any two labels
    -- ever overlap, say so in the preview rather than waiting for someone to
    -- notice on a screenshot.
    local hits = L.overlaps(page)
    if #hits > 0 then
        self:drawText("LAYOUT COLLISION: " .. tostring(hits[1].a) .. " / " .. tostring(hits[1].b),
                      12, self.height - 20, 1, 0.3, 0.3, 1, UIFont.Small)
    end
end

function VPSIndex.build()
    local p = Page:new(0, 0, W, H)
    p:initialise()
    return p
end

VPSIndex.W, VPSIndex.H = W, H
return VPSIndex

