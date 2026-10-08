--[[
    UIView — the Stir on a weapon's page and on the ladder (STIR_JOURNAL.md 4.2, 4.3)
    ===============================================================================
    The weapon page's Stir block sits under its marks, past the first screen of
    the scrolling page, so the panel preview never shows it. This mounts it
    whole, on a card at a page's width: a carried weapon (effects, what its next
    stage opens, its changes newest first) and the same weapon LOST (the bond
    kept all of it), then the Character ladder with each rung's Stir line.
    Emits "vpsstirblock"; asserts no collisions and that every piece is drawn.
]]

local Assert = PZTestKit.Assert
local Render = require "UIView/Render"
local Recorder = require "UIView/Recorder"
require "UIView/UIMock"
require "VorpallySauced/Knowledge"
require "VorpallySauced/Layout"
require "VorpallySauced/Chrome"
require "VorpallySauced/Provenance"
require "VorpallySauced/WeaponTraits"
require "VorpallySauced/Components"
require "VorpallySauced/Genome/Families"
require "VorpallySauced/Genome/Program"
require "VorpallySauced/Genome/Words"

local L = VorpallySauced.Layout
local C = VorpallySauced.Components
local Program = VorpallySauced.Genome.Program

L.setMeasurer(function(font, text)
    local tm = getTextManager()
    font = font or UIFont.Small
    return tm:MeasureStringX(font, tostring(text)), tm:MeasureStringY(font, tostring(text))
end)

local PAGE_W, PAGE_H, GAP = 460, 760, 18
local FONTS = { title = UIFont.Medium }

local function bond(lost)
    return {
        weaponId = 501, name = "Fire Axe", kills = 812, isFirearm = false, lost = lost,
        stir = Program.packClient({
            { ev = "kill", act = { id = "breath", amt = 6 } },
            { ev = "hit", act = { id = "stagger", amt = 20 } },
        }, 1.3, 3),
        stirStage = "Seasoned",
        stirLog = {
            { k = "born", a = "breath", kills = 214, place = { street = "Cortman Drive", band = "on" } },
            { k = "kept", kills = 388 },
            { k = "new", a = "stagger", kills = 506, place = { street = "Main Street", band = "near" } },
            { k = "stronger", a = "breath", kills = 731 },
        },
    }
end

local function ladder()
    local K = VorpallySauced.Knowledge
    local stages = {}
    for _, name in ipairs(VorpallySauced.WeaponTraits.STAGE_ORDER) do
        stages[#stages + 1] = { name = name, label = getText("UI_VorpallySauced_Trait_" .. name),
                                stir = K.stirOpens(name), color = C.INK }
    end
    return stages
end

local Host = ISPanel:derive("VPSStirBlockHost")
function Host:new(w, h)
    local o = ISPanel:new(0, 0, w, h)
    setmetatable(o, self); self.__index = self
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    return o
end

local trees = {}
local function build()
    SandboxVars.VorpallySauced = SandboxVars.VorpallySauced or {}
    SandboxVars.VorpallySauced.EnableGenome = true
    trees = {
        C.StirBlock({ bond = bond(false) }),
        C.StirBlock({ bond = bond(true) }),
        C.CharacterSpread({ stages = ladder(), moods = {}, fonts = FONTS }).left,
    }
end

function Host:prerender()
    ISPanel.prerender(self)
    build()
    for i, t in ipairs(trees) do
        local page = L.col({ pad = C.PAD }, t)
        local shell = C.Shell({ children = { C.Card({ children = { page } }) } })
        L.render(self, shell, GAP + (i - 1) * (PAGE_W + GAP), GAP, PAGE_W, PAGE_H)
    end
end

do
    local host = Host:new(PAGE_W * 3 + GAP * 4, PAGE_H + GAP * 2)
    host:initialise()
    Render.emit(host, host:getWidth(), host:getHeight(), "vpsstirblock")
end

local tests = {}

tests["stir_block_draws_its_parts_without_collisions"] = function()
    local host = Host:new(PAGE_W * 3 + GAP * 4, PAGE_H + GAP * 2)
    Render.frame(host, host:getWidth(), host:getHeight())
    local seen = {}
    for _, op in ipairs(Recorder.ops) do if op.op == "text" then seen[tostring(op.str)] = true end end
    local collisions = 0
    for _, t in ipairs(trees) do
        local page = L.col({ pad = C.PAD }, t)
        L.layout(page, 0, 0, PAGE_W - 40, nil)
        collisions = collisions + #L.overlaps(page)
    end
    local function has(s) for k in pairs(seen) do if k:find(s, 1, true) then return true end end return false end
    local ok = Assert.equal(collisions, 0, "no collisions on any of the three")
    ok = Assert.isTrue(has(getText("UI_VorpallySauced_JournalStirChanges")), "its changes are drawn") and ok
    ok = Assert.isTrue(has("Next stage"), "what its next stage opens") and ok
    ok = Assert.isTrue(has(getText("UI_VorpallySauced_JournalStirOpens_Tempered")), "the ladder's Stir lines") and ok
    return ok
end

return tests
