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

local fm = UIView_fontMetrics
local K = VorpallySauced.Knowledge
local Chrome = VorpallySauced.Chrome

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

--- Progress as a bar of the volume's own size, so the eight books stay
--- comparable at a glance (Vol. IV holds 7 entries, Vol. VII holds 43).
function Page:renderMeter(x, y, w, h, known, total, witnessed)
    self:drawRect(x, y, w, h, 0.10, INK[1], INK[2], INK[3])
    if total <= 0 then return end
    local kw = math.floor(w * known / total + 0.5)
    if kw > 0 then self:drawRect(x, y, kw, h, 0.30, INK[1], INK[2], INK[3]) end
    local ww = math.floor(w * witnessed / total + 0.5)
    if ww > 0 then self:drawRect(x, y, ww, h, 0.85, TEAL[1], TEAL[2], TEAL[3]) end
end

--- THE CONTENTS PAGE.
---
--- Eight rows, one per volume -- not 179 entries. The earlier draft put every
--- section on one surface and it was simply busy: a page of names and dashes
--- that answered "what exists" by showing all of it at once, which is the one
--- way to make 179 things feel like noise instead of a collection.
---
--- The index is a table of contents. It says what the game is made of, how big
--- each part is, and which parts you have opened -- the whole shape in eight
--- lines. The entries themselves live on a volume page, one book at a time,
--- which is also how you actually acquire them.
function Page:prerender()
    ISPanel.prerender(self)

    Chrome.nine(self, "lite_panel", 0, 0, self.width, self.height, 1)

    local cardX, cardY = PAD, PAD
    local cardW = self.width - PAD * 2
    local cardH = self.height - PAD * 2
    Chrome.nine(self, "lite_card", cardX, cardY, cardW, cardH, 1)

    local ci = Chrome.inset("lite_card") or 14
    Chrome.tile(self, "paper_tile", cardX + ci, cardY + ci,
                cardW - ci * 2, cardH - ci * 2, 0.35)

    local sections, summary = withFixture(function()
        return K.sections(nil), select(2, K.index(nil))
    end)

    local x = cardX + ci + 10
    local y = cardY + ci + 10
    local innerW = cardW - ci * 2 - 20
    local rule = Chrome.tex("stitch_rule")

    self:drawText("THE INDEX", x, y, INK[1], INK[2], INK[3], 1, UIFont.Medium)
    local head = ("%d of %d met"):format(summary.witnessed, summary.total)
    self:drawText(head, x + innerW - fw(UIFont.Small, head), y + 4,
                  MUTED[1], MUTED[2], MUTED[3], 1, UIFont.Small)
    y = y + fh(UIFont.Medium) + 6
    if rule then self:drawTextureScaled(rule, x, y, innerW, 4, 0.7, INK[1], INK[2], INK[3]) end
    y = y + 16

    local lineH = fh(UIFont.Small)

    -- MEASURE the number column instead of guessing it. A fixed 54px fits
    -- "Vol. I" and collides with "Vol. VIII", which renders as "Vol. VIIIBLOODED"
    -- -- and it only shows up on the last row, so a preview built from the
    -- first few volumes would look fine.
    local numW = 0
    for _, sec in ipairs(sections) do
        local v = sec.volume
        if v then numW = math.max(numW, fw(UIFont.Small, "Vol. " .. v.volumeNum)) end
    end
    local titleX = numW + 14

    for _, sec in ipairs(sections) do
        local vol = sec.volume
        local title = sectionTitle(sec)
        local num = vol and ("Vol. " .. vol.volumeNum) or ""

        -- An unopened book is quieter, not louder. (The first pass had this
        -- backwards -- collapsed sections used the LIGHTEST ink, so the thing
        -- you had never touched was the boldest line on the page.)
        local ink = sec.collapsed and FAINT or INK

        self:drawText(num, x, y, MUTED[1], MUTED[2], MUTED[3], 1, UIFont.Small)
        self:drawText(title, x + titleX, y, ink[1], ink[2], ink[3], 1, UIFont.Small)

        local count = ("%d / %d"):format(sec.known, sec.total)
        self:drawText(count, x + innerW - fw(UIFont.Small, count), y,
                      MUTED[1], MUTED[2], MUTED[3], 1, UIFont.Small)

        y = y + lineH + 3
        self:renderMeter(x + titleX, y, innerW - titleX - fw(UIFont.Small, "00 / 00") - 10, 3,
                         sec.known, sec.total, sec.witnessed)
        y = y + 5

        -- One line of state, which is also the lead.
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
        self:drawText(note, x + titleX, y, FAINT[1], FAINT[2], FAINT[3], 1, UIFont.Small)
        y = y + lineH + 12
    end
end

function VPSIndex.build()
    local p = Page:new(0, 0, W, H)
    p:initialise()
    return p
end

VPSIndex.W, VPSIndex.H = W, H
return VPSIndex
