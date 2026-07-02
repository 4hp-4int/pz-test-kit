--[[ pal_self — self orders: Stop (queue-aware, zero-state only while acting),
     meta combos (theme/opacity/fontsize as typed orders, head-Enter cycles),
     shout + emotes. Registered VOLATILE (fresh every open, cached in neither half). ]]
local Assert = PZTestKit.Assert
require "palette/pal_main"      -- pulls pal_self + SP.sourceVolatile + filter/groups
local SP = _G.SaucePalette
local SF = SP.Self
local S  = SP.Settings

-- player + action-queue harness: run fn with a mocked queue; returns a cleared() spy.
local function withQueue(actions, fn)
    local savedQ, savedP = _G.ISTimedActionQueue, _G.getSpecificPlayer
    local cleared = 0
    _G.ISTimedActionQueue = {
        getTimedActionQueue = function(_) return { queue = actions } end,
        clear = function(_) cleared = cleared + 1 end,
    }
    _G.getSpecificPlayer = function() return { _type = "IsoPlayer" } end
    local ok, err = pcall(fn, function() return cleared end)
    _G.ISTimedActionQueue, _G.getSpecificPlayer = savedQ, savedP
    if not ok then error(err) end
end

local function findRow(cmds, pred)
    for _, c in ipairs(cmds) do if pred(c) then return c end end
    return nil
end

local tests = {}

tests["self_source_is_volatile"] = function()
    local desc
    for _, s in ipairs(SP.sources) do if s.id == "self" then desc = s end end
    if not Assert.notNil(desc, "self source registered") then return false end
    if not Assert.isTrue(desc.volatile == true, "descriptor flags volatile") then return false end
    return Assert.isTrue(SP.sourceVolatile(desc), "SP.sourceVolatile agrees")
end

tests["stop_idle_is_blocked_and_hidden"] = function()
    local row
    withQueue({}, function()
        row = findRow(SF.collect(0), function(c) return c.kind == "stop" end)
    end)
    if not Assert.notNil(row, "Stop row exists even when idle (typed finds it)") then return false end
    if not Assert.isTrue(row.runnable == false, "idle Stop is blocked") then return false end
    if not Assert.notNil(row.blockReason, "idle Stop names the reason") then return false end
    return Assert.isTrue(row.alwaysMinor == true, "idle Stop hides from zero-state")
end

tests["stop_running_surfaces_with_action_name"] = function()
    local row
    withQueue({ { Type = "ISReadABook" } }, function()
        row = findRow(SF.collect(0), function(c) return c.kind == "stop" end)
    end)
    if not Assert.isTrue(row.runnable == true, "running Stop is runnable") then return false end
    if not Assert.isTrue(not row.alwaysMinor, "running Stop shows in zero-state") then return false end
    return Assert.equal(row.source, "Read A Book", "pretty action name on the right side")
end

tests["stop_run_uses_vanilla_full_clear"] = function()
    withQueue({ { Type = "ISReadABook" } }, function(cleared)
        local row = findRow(SF.collect(0), function(c) return c.kind == "stop" end)
        row.run()
        if not Assert.equal(cleared(), 1, "ISTimedActionQueue.clear called once") then error("spy") end
    end)
    return true
end

tests["theme_family_tags_current_and_cycles"] = function()
    local savedIdx, savedSet = S.comboIndex, S.setCombo
    local setCalls = {}
    S.comboIndex = function(which) return which == "theme" and 2 or 1 end
    S.setCombo = function(which, idx) setCalls[#setCalls + 1] = which .. "=" .. idx; return true end
    local rows
    withQueue({}, function()
        rows = {}
        for _, c in ipairs(SF.collect(0)) do
            if c.familyKey == "self.theme" then rows[#rows + 1] = c end
        end
    end)
    S.comboIndex, S.setCombo = savedIdx, savedSet
    if not Assert.equal(#rows, #S.THEME, "one row per skin") then return false end
    local cur, def
    for _, c in ipairs(rows) do
        if c.source then cur = c.familyOrder end
        if c.familyDefault then def = c.familyOrder end
        if not c.alwaysMinor then return Assert.isTrue(false, "theme rows are typed-only") end
    end
    if not Assert.equal(cur, 2, "current skin tagged") then return false end
    if not Assert.equal(def, 3, "family default = NEXT skin (head-Enter cycles)") then return false end
    -- running a row writes through S.setCombo with its own index
    local savedIdx2, savedSet2 = S.comboIndex, S.setCombo
    S.comboIndex = function() return 2 end
    S.setCombo = function(which, idx) setCalls[#setCalls + 1] = which .. "=" .. idx; return true end
    withQueue({}, function()
        for _, c in ipairs(SF.collect(0)) do
            if c.familyKey == "self.theme" and c.familyOrder == 4 then c.run() end
        end
    end)
    S.comboIndex, S.setCombo = savedIdx2, savedSet2
    return Assert.equal(setCalls[#setCalls], "theme=4", "run writes the row's index")
end

tests["setCombo_writes_option_and_saves_ini"] = function()
    local savedTheme, savedPZ = S._theme, _G.PZAPI
    local wrote, saved = nil, false
    S._theme = { setValue = function(_, v) wrote = v end }
    _G.PZAPI = { ModOptions = { save = function(_) saved = true end } }
    local ok = S.setCombo("theme", 2)
    S._theme, _G.PZAPI = savedTheme, savedPZ
    if not Assert.isTrue(ok, "setCombo accepts a valid index") then return false end
    if not Assert.equal(wrote, 2, "live PZAPI option written (Mod Options stays in sync)") then return false end
    return Assert.isTrue(saved, "ModOptions:save() persists to ini")
end

tests["setCombo_rejects_bad_index"] = function()
    if not Assert.isTrue(S.setCombo("theme", 0) == false, "0 rejected") then return false end
    if not Assert.isTrue(S.setCombo("theme", #S.THEME + 1) == false, "past-end rejected") then return false end
    return Assert.isTrue(S.setCombo("nosuch", 1) == false, "unknown combo rejected")
end

tests["emotes_and_shout_present"] = function()
    local rows, shout
    withQueue({}, function()
        rows = {}
        for _, c in ipairs(SF.collect(0)) do
            if c.familyKey == "self.emote" then rows[#rows + 1] = c end
            if c.kind == "character" and not c.familyKey then shout = c end
        end
    end)
    if not Assert.equal(#rows, #SF.EMOTES, "one row per radial emote") then return false end
    if not Assert.notNil(shout, "Shout row present") then return false end
    return Assert.isTrue(shout.alwaysMinor == true, "character verbs are typed-only vocabulary")
end

tests["emote_variant_pick_mirrors_radial"] = function()
    local savedZR, savedP = _G.ZombRand, _G.getSpecificPlayer
    local played
    _G.ZombRand = function(_) return 1 end   -- 0-based -> +1 = second variant
    _G.getSpecificPlayer = function() return { playEmote = function(_, e) played = e end } end
    SF.playEmote(0, "salute")
    _G.ZombRand, _G.getSpecificPlayer = savedZR, savedP
    return Assert.equal(played, "salutecasual", "variant table consulted like the radial")
end

tests["markMinor_preserves_alwaysMinor"] = function()
    local cmds
    withQueue({}, function() cmds = SF.collect(0) end)
    SP.Groups.markMinor(cmds)
    local stop = findRow(cmds, function(c) return c.kind == "stop" end)
    local theme = findRow(cmds, function(c) return c.familyKey == "self.theme" end)
    if not Assert.isTrue(stop.minor == true, "idle Stop stays minor through the reset") then return false end
    return Assert.isTrue(theme.minor == true, "meta rows stay minor through the reset")
end

tests["categories_registered"] = function()
    if not Assert.equal(SP.Filter.CAT_RANK.stop, 0.2, "STOP ranks first") then return false end
    if not Assert.equal(SP.Filter.CAT_RANK.meta, 13.5, "META recedes") then return false end
    local T = require "palette/pal_theme"
    if not Assert.equal(T.color.category.stop[1], "STOP", "STOP chip registered") then return false end
    return Assert.equal(T.color.category.meta[1], "META", "META chip registered")
end

return tests
