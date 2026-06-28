--[[
    UIView — pal_medical detection + emission tests
    ===============================================
    Drives the REAL pal_medical.collect() against a mock player/body/inventory to
    verify which injuries surface which treatment verbs, runnable vs blocked, and
    the body-part gating (no splinting the torso). Execution of the first-aid
    actions is validated in-game, not here.
]]

local Assert = PZTestKit.Assert
local Med    = require "UIView/scenes/PaletteMedical"

local tests = {}

tests["healthy_player_gates_to_empty"] = function()
    local cmds = Med.collectWith({ hasMoodle = false,
        parts = { { fracture = 10 } } })   -- injury present but NO moodle -> gated
    return Assert.equal(#cmds, 0, "no injury moodle -> provider does no work")
end

tests["fracture_with_splint_is_runnable"] = function()
    local cmds = Med.collectWith({ hasMoodle = true,
        parts = { { type = "Hand_L", fracture = 10 } },
        items = { { type = "Splint" } } })
    local c = Med.find(cmds, "Splint")
    if not Assert.notNil(c, "a Splint command was emitted") then return false end
    return Assert.isTrue(c.runnable == true, "Splint is runnable when you hold a splint")
end

tests["fracture_without_splint_is_blocked"] = function()
    local cmds = Med.collectWith({ hasMoodle = true,
        parts = { { type = "Hand_L", fracture = 10 } },
        items = {} })
    local c = Med.find(cmds, "Splint")
    if not Assert.notNil(c, "Splint command emitted even without the item") then return false end
    if not Assert.isTrue(c.runnable == false, "Splint is blocked without a splint") then return false end
    return Assert.notNil(c.blockReason, "blocked Splint shows a reason")
end

tests["plank_plus_ripped_sheets_splints"] = function()
    local cmds = Med.collectWith({ hasMoodle = true,
        parts = { { type = "Hand_L", fracture = 10 } },
        items = { { type = "Plank" }, { type = "RippedSheets" } } })
    local c = Med.find(cmds, "Splint")
    return Assert.isTrue(c ~= nil and c.runnable == true, "plank + ripped sheets makes a runnable splint")
end

tests["cannot_splint_the_torso"] = function()
    local cmds = Med.collectWith({ hasMoodle = true,
        parts = { { type = "Torso_Upper", fracture = 10 } } })
    return Assert.isNil(Med.find(cmds, "Splint"), "no Splint option on the torso")
end

tests["embedded_glass_with_tweezers"] = function()
    local cmds = Med.collectWith({ hasMoodle = true,
        parts = { { type = "Hand_R", glass = true } },
        items = { { type = "Tweezers" } } })
    local c = Med.find(cmds, "Remove Glass")
    return Assert.isTrue(c ~= nil and c.runnable == true, "Remove Glass runnable with tweezers")
end

tests["deep_wound_with_suture_stitches"] = function()
    local cmds = Med.collectWith({ hasMoodle = true,
        parts = { { type = "ForeArm_L", deep = true } },
        items = { { type = "SutureNeedle" } } })
    local c = Med.find(cmds, "Stitch")
    return Assert.isTrue(c ~= nil and c.runnable == true, "Stitch runnable with a suture needle")
end

tests["infection_surfaces_disinfect"] = function()
    local cmds = Med.collectWith({ hasMoodle = true,
        parts = { { type = "ForeArm_L", infection = 0.5 } },
        items = {} })
    -- disinfect needs an alcohol item we didn't give -> blocked but present
    local c = Med.find(cmds, "Disinfect")
    return Assert.isTrue(c ~= nil, "Disinfect surfaces for an infected wound")
end

tests["part_detail_lists_injuries_and_consumed_item"] = function()
    local SP = _G.SaucePalette
    local f = function(v) return function() return v end end
    local part = { bleeding = f(true), isDeepWounded = f(false), getFractureTime = f(0),
        haveGlass = f(false), haveBullet = f(false), isBurnt = f(false), getStitchTime = f(0),
        getPain = f(20), getHealth = f(55) }
    local d = SP.Medical.partDetail(part, { verb = "Bandage", need = "need a bandage" },
        { getName = f("Bandage") }, "Left Arm")
    local has = {}
    for _, r in ipairs(d.rows) do has[tostring(r.text)] = true end
    return Assert.isTrue(has["bleeding"] and has["in pain"] and has["part health"] and has["Bandage"],
        "lists the injuries (bleeding / in pain), part health, and names the consumed bandage")
end

tests["part_detail_survives_missing_methods"] = function()
    -- the existence-guard: a part exposing only getHealth must NOT crash partDetail
    -- (the in-game crash class — a nil :method() escapes pcall).
    local SP = _G.SaucePalette
    local part = { getHealth = function() return 80 end }
    local d
    local ok = pcall(function() d = SP.Medical.partDetail(part, { verb = "Bandage" }, nil, "Hand") end)
    if not Assert.isTrue(ok, "partDetail does not error when injury methods are absent") then return false end
    local found = false
    for _, r in ipairs(d.rows) do if r.text == "part health" then found = true end end
    return Assert.isTrue(found, "still shows part health from the one method present")
end

return tests
