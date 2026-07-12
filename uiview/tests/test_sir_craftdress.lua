--[[
    SIR — craft/build window dress (sir_craftdress)
    ================================================
    First lock for the craftdress surface: the dress/restore round-trip on a
    mock window tree. dressPre must suppress the shell + bare the interior +
    re-seat list selection on the look's wash; turning the option off must
    hand every field back to vanilla untouched.
]]

local Assert = PZTestKit.Assert

require "UIView/UIMock"
require "sir_chrome"
local SIR = _G.SauceInvRender
local T = require "sir_theme"
require "sir_craftdress"

local Render = require "UIView/Render"
local Recorder = require "UIView/Recorder"
local CraftInv = require "UIView/scenes/CraftInv"

-- emit the dressed craft window for the contact sheet + golden
pcall(function() Render.emit(CraftInv.build(), nil, nil, "craftdress") end)

-- controllable option + guard (saved/restored so later test files in the
-- same runner see the real ones)
local origOptBool, origGuard = SIR.optBool, SIR.Guard
local dressEnabled = true

local function withStubs(fn)
    SIR.optBool = function(key, def)
        if key == "sir_craftdress" then return dressEnabled end
        if origOptBool then return origOptBool(key, def) end
        return def
    end
    SIR.Guard = SIR.Guard or { tripped = {}, trip = function() end }
    local ok, err = pcall(fn)
    SIR.optBool, SIR.Guard = origOptBool, origGuard
    if not ok then error(err) end
end

local function mkWin()
    local win = {
        backgroundColor = { a = 0.8 }, borderColor = { a = 1 },
        titlebarbkg = "vanilla_titlebar", isCollapsed = false,
        children = {}, width = 400, height = 300,
    }
    function win:titleBarHeight() return 16 end
    function win:getWidth() return self.width end
    function win:getHeight() return self.height end
    function win:drawTextureScaled() end
    function win:drawTextureScaledColor() end
    function win:DrawTextureScaledColor() end
    function win:drawRect() end
    -- a scrolling-list-shaped child (recipes / categories / craft inventory)
    local list = {
        selectedColor = { r = 0.7, g = 0.05, b = 0.05, a = 0.3 },
        mouseOverColor = { r = 0, g = 0, b = 0, a = 0.3 },
        doDrawItem = function() end,
        backgroundColor = { a = 0.85 }, borderColor = { a = 1 },
        children = {},
    }
    -- a plain panel child (XUI fill carrier)
    local panel = { backgroundColor = { a = 0.7 }, borderColor = { a = 0.9 }, children = {} }
    win.children[1] = list
    win.children[2] = panel
    return win, list, panel
end

local tests = {}

tests["dress_and_restore_round_trip"] = function()
    local ok = true
    withStubs(function()
        pcall(function() SIR.Chrome.resolve() end)
        local win, list, panel = mkWin()
        local origSel = list.selectedColor

        dressEnabled = true
        SIR.CraftDress.dressPre(win)
        ok = Assert.equal(win.backgroundColor.a, 0, "shell fill suppressed") and ok
        ok = Assert.equal(panel.backgroundColor.a, 0, "interior panel bared") and ok
        ok = Assert.equal(list.backgroundColor.a, 0, "list fill bared") and ok
        local wsh = T.ink.wash
        ok = Assert.equal(list.selectedColor.r, wsh[1], "selection rides the look's wash") and ok
        ok = Assert.equal(list.selectedColor.a, T.rowA.select, "selection at the rowA ladder alpha") and ok
        ok = Assert.equal(list.mouseOverColor.a, T.rowA.hover, "hover at the rowA ladder alpha") and ok
        ok = Assert.isTrue(list.selectedColor ~= origSel, "original selection table preserved aside") and ok

        dressEnabled = false
        SIR.CraftDress.dressPre(win)
        ok = Assert.equal(win.backgroundColor.a, 0.8, "shell fill restored") and ok
        ok = Assert.equal(panel.backgroundColor.a, 0.7, "interior panel restored") and ok
        ok = Assert.isTrue(list.selectedColor == origSel, "selection handed back to vanilla's table") and ok
        ok = Assert.equal(win.titlebarbkg, "vanilla_titlebar", "titlebar texture restored") and ok
    end)
    return ok
end

tests["scene_wears_the_shell_and_bares_the_control_strip"] = function()
    -- the CraftInv scene through the real dress: wincap + ledger painted,
    -- and the craft-control strip's hardcoded {0.2,0.2,0.2,0.5} fill bared.
    -- (The wash selection re-seat is locked by the round-trip test — the
    -- harness listbox paints selection hardcoded, unlike the real base.)
    local win = CraftInv.build()
    Render.frame(win, 560, 400)
    local sawCap, sawLedger, sawCtrlFill = false, false, false
    for _, o in ipairs(Recorder.ops) do
        local n = tostring(o.name or "")
        if n:find("wincap", 1, true) then sawCap = true end
        if n:find("ledger", 1, true) then sawLedger = true end
        if o.op == "rect" and math.abs((o.a or 0) - 0.5) < 0.01
            and math.abs((o.r or 0) - 0.2) < 0.01 then sawCtrlFill = true end
    end
    local sawTicket = false
    for _, o in ipairs(Recorder.ops) do
        local n = tostring(o.name or '')
        if n:find('chip', 1, true) and math.abs((o.r or 0) - 0.72) < 0.02
            and math.abs((o.g or 0) - 0.21) < 0.02 then sawTicket = true end
    end
    return Assert.isTrue(sawCap, "cherry wincap on the title band")
        and Assert.isTrue(sawLedger, "kraft ledger under the body")
        and Assert.isTrue(not sawCtrlFill, "control strip's hardcoded fill bared by the walk")
        and Assert.isTrue(sawTicket, "cherry ticket chips on the primary buttons (regression lock)")
end

return tests
