--[[ Lens -> palette ranking bridge (pure re-ranking).
     A Combat lens floats combat verbs (equip / reload) via the SAME cat/lbl
     channels as moodles, without hiding or reordering anything destructively,
     and an acute need (bleeding) still outranks the lens. ]]
local Assert = PZTestKit.Assert
require "sir_lens"
require "palette/pal_needs"

local SP = _G.SaucePalette
local N  = SP.Needs
local SIR = _G.SauceInvRender

local function cmd(category, label) return { category = category, label = label } end

local tests = {}

tests["lens_off_no_boost"] = function()
    SIR.Lens.set(0)
    local snap = N.snapshot(0)
    return Assert.equal(N.boostFor(cmd("equip", "Equip Pistol"), snap), 0, "equip unboosted when no lens")
end

tests["combat_lens_floats_equip"] = function()
    SIR.Lens.set("combat")
    local snap = N.snapshot(0)
    local eq = N.boostFor(cmd("equip", "Equip Pistol"), snap)
    local rd = N.boostFor(cmd("read",  "Read Book"),     snap)
    SIR.Lens.set(0)
    if not Assert.equal(eq, 2000, "equip floated to lens weight") then return false end
    return Assert.equal(rd, 0, "unrelated verb (read) untouched by combat lens")
end

tests["combat_lens_label_keyword"] = function()
    SIR.Lens.set("combat")
    local snap = N.snapshot(0)
    local rl = N.boostFor(cmd("use", "Reload Pistol"), snap)   -- lbl reload=2100 beats cat use=1700
    SIR.Lens.set(0)
    return Assert.equal(rl, 2100, "reload keyword wins via lbl channel")
end

tests["lens_does_not_outrank_acute_need"] = function()
    -- The lens boost (equip 2000) must sit UNDER an acute moodle. We can't drive a
    -- real bleeding moodle headlessly, so simulate the merge: a snapshot already
    -- carrying a high med boost stays higher than the lens's equip boost.
    SIR.Lens.set("combat")
    local snap = N.snapshot(0)
    snap.cat.med = 3000                 -- stand-in for a Bleeding moodle
    local med = N.boostFor(cmd("med",   "Bandage Wound"), snap)
    local eq  = N.boostFor(cmd("equip", "Equip Pistol"),  snap)
    SIR.Lens.set(0)
    return Assert.greater(med, eq, "acute need outranks ambient lens")
end

return tests
