--[[
    UIView — Scene: the craft window wearing SIR's craftdress
    ==========================================================
    A hand-craft-window-shaped tree built from REAL vanilla widgets (an
    ISCollapsableWindow shell hosting the category list, the recipe list and
    a craft-control strip), dressed by the REAL SIR.CraftDress.dressPre wrap
    — the same code path the in-game B window takes. Goldens lock the shell
    chrome (wincap + ledger), the interior bare-walk, and the list
    selection re-seated on the look's wash.
]]

require "UIView/UIWidgets"
UIView_setScreen(1280, 800)

require "sir_chrome"
require "sir_craftdress"

local CraftInv = {}

function CraftInv.build()
    local SIR = _G.SauceInvRender
    -- the module's dressOn() reads the guard + option; give the scene the
    -- same defaults the game has when neither has been touched
    SIR.Guard = SIR.Guard or { tripped = {}, trip = function() end }

    local win = ISCollapsableWindow:new(10, 10, 520, 360)
    win:setTitle("Craft")
    win:initialise()
    -- the harness widget's own titleBarHeight throws (reads unset font
    -- metrics at call time) — pin the scene's rail height instead
    function win:titleBarHeight() return 16 end
    win.backgroundColor = win.backgroundColor or { a = 0.8 }
    win.borderColor = win.borderColor or { a = 1 }

    -- category column (vanilla: a plain ISScrollingListBox)
    local cats = ISScrollingListBox:new(8, 24, 140, 300)
    cats:initialise()
    cats:addItem("All")
    cats:addItem("Carpentry")
    cats:addItem("Cooking")
    cats:addItem("Survival")
    cats.selected = 2
    win:addChild(cats)

    -- recipe list (vanilla rows; selection is the base-class field paint)
    local recipes = ISScrollingListBox:new(156, 24, 220, 300)
    recipes:initialise()
    recipes:addItem("Plank and Nails Wall")
    recipes:addItem("Wooden Crate")
    recipes:addItem("Sturdy Chair")
    recipes:addItem("Small Table")
    recipes.selected = 2
    win:addChild(recipes)

    -- craft-control strip: ISWidgetHandCraftControl's shape — a panel that
    -- paints its own hardcoded {0.2,0.2,0.2,0.5} fill each frame + a button
    local ctrl = ISPanel:new(384, 24, 128, 300)
    ctrl:setBackgroundColor(0.2, 0.2, 0.2, 0.5)
    ctrl.background = true
    ctrl:initialise()
    local craftBtn = ISButton:new(14, 260, 100, 26, "Craft", ctrl, function() end)
    craftBtn:initialise()
    ctrl:addChild(craftBtn)
    win:addChild(ctrl)

    -- the module's wrap, verbatim shape (the real classes are wrapped at
    -- require time; the scene window is a stand-in built after that)
    local origPrerender = win.prerender
    win.prerender = function(self)
        local ok, err = pcall(function() SIR.CraftDress.dressPre(self) end)
        if not ok then SIR.Guard.trip("craftdress", err) end
        origPrerender(self)
    end

    win._scene = { cats = cats, recipes = recipes, ctrl = ctrl }
    return win
end

return CraftInv
