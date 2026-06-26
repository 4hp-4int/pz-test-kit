--[[
    UIView — pal_foraging (enable/disable the search overlay)
    =========================================================
    Drives the real foraging collect() against a stubbed ISSearchManager. Asserts the
    state-aware toggle (Enable when off / Disable when on), the foraging-window member,
    the block reason when the game forbids enabling (checkShouldDisable), and that run
    calls toggleSearchMode with the flipped state.
]]

local Assert = PZTestKit.Assert
local SP = require "palette/pal_foraging"

local function foragingCollect()
    for _, s in ipairs(SP.sources) do if s.id == "foraging" then return s.collect end end
end

-- stub the search manager. `on` = current mode, `cant` = checkShouldDisable result.
local function withManager(on, cant)
    local mgr = { isSearchMode = on, _toggledTo = nil }
    mgr.checkShouldDisable = function() return cant or false end
    mgr.toggleSearchMode   = function(self, v) self._toggledTo = v end
    _G.ISSearchManager = { getManager = function() return mgr end }
    _G.ISSearchWindow  = { showWindow = function() end }
    _G._pz_player = { _type = "IsoPlayer" }
    return mgr
end

local function find(cmds, sub)
    for _, c in ipairs(cmds) do if tostring(c.label):find(sub, 1, true) then return c end end
    return nil
end

local tests = {}

tests["off_offers_enable"] = function()
    withManager(false, false)
    local cmds = foragingCollect()(0)
    if not Assert.notNil(find(cmds, "Enable Foraging"), "off -> Enable Foraging row") then return false end
    return Assert.isTrue(find(cmds, "Enable Foraging").runnable == true, "enable is runnable when allowed")
end

tests["on_offers_disable"] = function()
    withManager(true, false)
    local cmds = foragingCollect()(0)
    return Assert.notNil(find(cmds, "Disable Foraging"), "on -> Disable Foraging row")
end

tests["window_member_present"] = function()
    withManager(false, false)
    return Assert.notNil(find(foragingCollect()(0), "Foraging Window"), "the foraging window is offered")
end

tests["enable_blocked_with_reason"] = function()
    withManager(false, true)   -- sprinting/driving -> can't enable
    local row = find(foragingCollect()(0), "Enable Foraging")
    if not Assert.isTrue(row.runnable == false, "enable greyed when the game forbids it") then return false end
    return Assert.notNil(row.blockReason, "and it carries a reason")
end

tests["run_toggles_flipped_state"] = function()
    local mgr = withManager(false, false)
    local row = find(foragingCollect()(0), "Enable Foraging")
    row.run()
    return Assert.isTrue(mgr._toggledTo == true, "running Enable calls toggleSearchMode(true)")
end

tests["forage_rows_are_forage_category"] = function()
    withManager(false, false)
    return Assert.equal(find(foragingCollect()(0), "Enable Foraging").category, "forage", "rows carry the forage category")
end

tests["family_collapses_under_one_node"] = function()
    withManager(true, false)
    local cmds = foragingCollect()(0)
    SP.Families.apply(cmds)
    if not Assert.equal(cmds[1].familyKey, cmds[2].familyKey, "both members share one family") then return false end
    return Assert.equal(cmds[1].familyLabel, "Foraging", "family head = Foraging")
end

return tests
