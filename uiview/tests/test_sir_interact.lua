--[[
    UIView — scripted INTERACTION tests (Interact.lua step 1)
    =========================================================
    Drives the REAL SIRSearchBar input paths the way PZ's UIManager would:
    hit-tested clicks with element-local coords, text entry via the polled
    mock buffer, Escape through onOtherKey. The band-rides-the-scroll saga
    motivated this: interaction behavior must be able to FAIL headlessly.
]]

local Assert   = PZTestKit.Assert
local Render   = require "UIView/Render"
local Recorder = require "UIView/Recorder"
local Interact = require "UIView/Interact"
local SIRInv   = require "UIView/scenes/SIRInv"

local function frame(page)
    Render.frame(page, page.width + 16, page.height + 16)
    return Recorder.ops
end

local function paintedNames(ops)
    local seen = {}
    for _, o in ipairs(ops) do
        if o.op == "text" then seen[#seen + 1] = tostring(o.str) end
    end
    return table.concat(seen, "|")
end

local tests = {}

tests["chip_click_filters_the_list"] = function()
    local page = SIRInv.build({})
    frame(page)                                   -- latch chrome + layout
    local bar = page.sirSearchBar
    local chip
    for _, c in ipairs(bar._chips or {}) do
        if c.key == "food" then chip = c end
    end
    local ax, ay = bar:getAbsoluteX(), bar:getAbsoluteY()
    local handler = Interact.click(page, ax + chip.x + 2, ay + chip.y + 2)
    local ops = frame(page)
    local names = paintedNames(ops)
    return Assert.isTrue(handler ~= nil, "click dispatched to a handler")
        and Assert.equal(page.sirFilter.cat, "food", "Food chip set the filter")
        and Assert.isTrue(names:find("Apple", 1, true) ~= nil, "food rows still painted")
        and Assert.isTrue(names:find("Pistol", 1, true) == nil, "non-food rows filtered out")
end

tests["typed_search_narrows_and_escape_clears"] = function()
    local page = SIRInv.build({})
    frame(page)
    local bar = page.sirSearchBar
    Interact.type(bar.entry, "steak")
    frame(page)                                   -- bar polls the entry each prerender
    local narrowed = page.sirFilter.text
    local ops = frame(page)
    local names = paintedNames(ops)
    local onlySteak = names:find("Rotten Steak", 1, true) ~= nil
        and names:find("Baseball", 1, true) == nil
    -- Escape routes through onOtherKey (the real UITextBox2 path) and clears
    Interact.type(bar.entry, nil, Keyboard and Keyboard.KEY_ESCAPE or 1)
    frame(page)
    return Assert.equal(narrowed, "steak", "typed text applied to the filter")
        and Assert.isTrue(onlySteak, "list narrowed to the match")
        and Assert.equal(page.sirFilter.text, "", "Escape cleared the search")
end

tests["chevron_click_collapses_the_band"] = function()
    local page = SIRInv.build({})
    frame(page)
    local bar = page.sirSearchBar
    local cv = bar._chevRect
    local ax, ay = bar:getAbsoluteX(), bar:getAbsoluteY()
    Interact.click(page, ax + cv.x + 2, ay + cv.y + 2)
    frame(page)                                   -- tween settles instantly headless (T.now()==0)
    local collapsed = bar.collapsed
    local shortBand = bar:getHeight() == bar:collapsedHeight()
    -- click anywhere on the collapsed strip re-expands
    Interact.click(page, ax + 10, ay + 4)
    frame(page)
    return Assert.isTrue(collapsed, "chevron click collapsed the band")
        and Assert.isTrue(shortBand, "band height snapped to the collapsed strip")
        and Assert.isTrue(bar.collapsed == false, "clicking the strip re-expands")
end

return tests
