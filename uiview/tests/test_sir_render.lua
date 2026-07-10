--[[
    UIView — SauceInvRender inventory rendering
    ===========================================
    Drives the REAL SIR.renderdetails over mock item stacks and asserts it paints
    a populated display list (icons / condition bars / badges). Emits the "sirinv"
    scene for the visual contact sheet (./uiview.sh sirinv).
]]

local Assert  = PZTestKit.Assert
local Render  = require "UIView/Render"
local Recorder = require "UIView/Recorder"
local SIRInv  = require "UIView/scenes/SIRInv"

-- emit the scene for headless viewing (guarded so a render error reports clearly)
do
    local ok, err = pcall(function() Render.emit(SIRInv.build({ look = "lamplight" }), nil, nil, "sirinv") end)
    pcall(function() Render.emit(SIRInv.build({}), nil, nil, "sirdaylight") end)
    pcall(function() Render.emit(SIRInv.build({ opacity = 3 }), nil, nil, "sirglass") end)
    pcall(function() Render.emit(SIRInv.build({ opacity = 3, scroll = -50, equipped = true }), nil, nil, "sirscroll") end)
    pcall(function() Render.emit(SIRInv.build({ fontScale = 1.8 }), nil, nil, "sirbigfont") end)
    -- midnight emits LAST: the harness element-id counter is global per run,
    -- so inserting a scene mid-list would shift every later golden's el ids
    pcall(function() Render.emit(SIRInv.build({ look = "midnight" }), nil, nil, "sirmidnight") end)
    if UIMock_setFontScale then UIMock_setFontScale(1) end
    if not ok then print("[sirinv] BUILD/EMIT ERROR: " .. tostring(err)) end
end

local function opsOf(pane)
    Render.frame(pane, pane.width + 16, pane.height + 16)
    return Recorder.ops
end
local function countOp(ops, kind)
    local n = 0
    for _, o in ipairs(ops) do if o.op == kind then n = n + 1 end end
    return n
end

local tests = {}

tests["renderdetails_runs_and_paints"] = function()
    local pane = SIRInv.build({})
    local ops = opsOf(pane)
    return Assert.greater(#ops, 20, "SIR.renderdetails produced a populated display list")
end

tests["paints_condition_bars"] = function()
    -- weapons/tools with condition draw filled rects for the bar
    local pane = SIRInv.build({})
    local ops = opsOf(pane)
    return Assert.greater(countOp(ops, "rect"), 5, "condition bars / backgrounds painted as rects")
end

tests["paints_item_icons"] = function()
    local pane = SIRInv.build({})
    local ops = opsOf(pane)
    local tex = countOp(ops, "texture")
    return Assert.greater(tex, 0, "item icons / badges painted as textures")
end

tests["paints_item_names"] = function()
    local pane = SIRInv.build({})
    local ops = opsOf(pane)
    local found = false
    for _, o in ipairs(ops) do
        if o.op == "text" and tostring(o.str):find("Pistol", 1, true) then found = true end
    end
    return Assert.isTrue(found, "item names rendered")
end

tests["header_band_masks_scrolled_rows"] = function()
    -- The band must draw AFTER the rows (it is the opaque mask that hides rows
    -- scrolled above headerHgt -- the in-game bug the old draw order shipped),
    -- and it must ignore the transparency slider (alpha 1 even at Glass).
    local pane = SIRInv.buildPane({ headerHgt = 15, scroll = -50 })
    local ops = opsOf(pane)
    local lastRowText, firstBand, bandAlpha = 0, nil, nil
    for i, o in ipairs(ops) do
        if o.op == "text" and tostring(o.str):find("Pistol", 1, true) then lastRowText = i end
        if o.op == "texture" and tostring(o.name):find("ledghead", 1, true) and not firstBand then
            firstBand = i
            bandAlpha = o.a
        end
    end
    -- scroll-transform + stencil truth: the Static-pinned band stays at y>=0,
    -- and the first row (scrolled above the viewport) is CLIPPED -- its text
    -- must not paint at all (the mock models the pane's GL-scissor stencil).
    local bandY, pistolPainted = nil, false
    for i, o in ipairs(ops) do
        if o.op == "texture" and tostring(o.name):find("ledghead", 1, true) and bandY == nil then
            bandY = o.y
        end
        if o.op == "text" and tostring(o.str):find("Pistol", 1, true) then pistolPainted = true end
    end
    return Assert.isTrue(firstBand ~= nil, "header band painted")
        and Assert.greater(firstBand, lastRowText, "band draws AFTER the row content (opaque mask)")
        and Assert.equal(bandAlpha, 1, "band ignores the opacity slider")
        and Assert.isTrue(bandY ~= nil and bandY >= 0, "band is scroll-PINNED (Static draw)")
        and Assert.isTrue(not pistolPainted, "scrolled-off row clipped by the pane stencil")
end

tests["window_dress_bares_vanilla_children"] = function()
    -- Full window: the dress must zero the pane fill, the sort-header plates,
    -- and swap the scrollbar thumb fields (the in-game vanilla survivors).
    local page = SIRInv.build({})
    Render.frame(page, page.width + 16, page.height + 16)
    local pane = page.inventoryPane
    return Assert.equal(pane.backgroundColor.a, 0, "pane black fill bared")
        and Assert.equal(pane.nameHeader.backgroundColor.a, 0, "sort-header plate bared")
        and Assert.isTrue(pane.vscroll.toptex ~= nil, "scrollbar capsule fields swapped")
        and Assert.equal(page.borderColor.a, 0, "square window border gone")
        and Assert.equal(page.closeButton.width, 12, "rail buttons shrunk to 12px")
        and Assert.isTrue(page.closeButton._sirGlyph == true, "rail glyph swapped in (sir_ui-close)")
        and Assert.isTrue(pane.expandAll._sirGlyph == true, "header glyph swapped in (sir_ui-expand)")
end

tests["midnight_look_swaps_glass_set"] = function()
    -- Midnight is the only look with its OWN rails/entry/thumb: the window
    -- must paint ledger_mid/wincap_mid pieces (not the kraft/cherry set) and
    -- the scrollbar capsule must re-dress to the frosted _mid thumb.
    local page = SIRInv.build({ look = "midnight" })
    Render.frame(page, page.width + 16, page.height + 16)
    local T = require "sir_theme"
    local ops = Recorder.ops
    local sawMidBody, sawMidCap, sawStockRail = false, false, false
    for _, o in ipairs(ops) do
        local n = tostring(o.name or "")
        if n:find("sir_ledger_mid_", 1, true) then sawMidBody = true end
        if n:find("sir_wincap_mid_", 1, true) then sawMidCap = true end
        -- un-suffixed cherry rail pieces must NOT paint on midnight
        if n:find("sir_wincap_t", 1, true) or n:find("sir_winfoot_t", 1, true) then
            sawStockRail = true
        end
    end
    local thumbMid = tostring(page.inventoryPane.vscroll.toptex or ""):find("vthumb_mid", 1, true) ~= nil
        or (page.inventoryPane.vscroll._sirCapsuleLook == "midnight")
    local ok = Assert.equal(T.look, "midnight", "look applied via the real optIndex path")
        and Assert.isTrue(sawMidBody, "ledger_mid body painted")
        and Assert.isTrue(sawMidCap, "wincap_mid rail painted")
        and Assert.isTrue(not sawStockRail, "cherry rails do NOT paint on midnight")
        and Assert.isTrue(thumbMid, "scrollbar capsule re-dressed to the _mid thumb")
    return ok
end

tests["midnight_stripes_go_luminance_but_palette_stays_canonical"] = function()
    -- catStripe maps stripes to the white luminance ramp on midnight WITHOUT
    -- mutating T.color.cat (the cross-mod palette weld reads the canonical
    -- hues; the tooltip card is kraft-pinned and keeps colour accents).
    local T = require "sir_theme"
    local wr, wg, wb = T.color.cat.weapon[1], T.color.cat.weapon[2], T.color.cat.weapon[3]
    T.setLook("midnight")
    local s = T.catStripe("weapon")
    local lum = Assert.isTrue(s[1] == s[2] and s[2] == s[3], "midnight stripe is grayscale")
    local canon = Assert.equal(T.color.cat.weapon[1], wr, "canonical hue untouched (r)")
        and Assert.equal(T.color.cat.weapon[2], wg, "canonical hue untouched (g)")
        and Assert.equal(T.color.cat.weapon[3], wb, "canonical hue untouched (b)")
    T.setLook("lamplight")
    local back = T.catStripe("weapon")
    local restored = Assert.equal(back[1], wr, "non-midnight stripe returns the canonical hue")
    return lum and canon and restored
end

tests["font_scale_clamps_hold"] = function()
    -- The in-game font-size option scales the band and rail; the glyph MARKS
    -- must stay icon-sized (forced dims) and the header glyph slots must stay
    -- left of column2 (the Item sort header). Both were real in-game bugs the
    -- 1x-only harness could not see.
    local page = SIRInv.build({ fontScale = 1.8 })
    Render.frame(page, page.width + 16, page.height + 16)
    local ops = Recorder.ops
    -- column model: every header control glyph (expand/collapse over the expand
    -- column, filter funnel over the icon column) must stay left of the NAME
    -- column (shared SIR.rowGeom) and cap at icon size -- one uniform control
    -- size seated in its own column, no collision.
    local nameX = _G.SauceInvRender.rowGeom(page.inventoryPane.itemHgt).nameX
    local sawGlyph, fits, capped = false, true, true
    for _, o in ipairs(ops) do
        local n = tostring(o.name or "")
        if n:find("sir_ui-expand", 1, true) or n:find("sir_ui-collapse", 1, true)
           or n:find("sir_ui-funnel", 1, true) then
            sawGlyph = true
            if (o.x or 0) + (o.w or 0) > nameX then fits = false end
            if (o.w or 0) > 16 then capped = false end
        end
    end
    if UIMock_setFontScale then UIMock_setFontScale(1) end
    local T = require "sir_theme"
    if T.metricsRefresh then T.metricsRefresh() end
    return Assert.isTrue(sawGlyph, "a header control glyph rendered at 1.8x font")
        and Assert.isTrue(fits, "header glyphs stay left of the name column")
        and Assert.isTrue(capped, "glyph marks capped at icon size")
end

tests["corner_button_rides_the_weight_capsule"] = function()
    -- vanilla welds the readout to the pin button (drawTextRight at
    -- pinButton:getX()) — air between them is structurally impossible, so
    -- the pill extends UNDER the corner button: [readout | pin] is ONE
    -- capsule, the pin (or pin-off while pinned) a control seated on the
    -- meter. Field reports: the glyph "overlapping" the number.
    local page = SIRInv.build({})
    local function frameAndMeasure(glyph)
        Render.frame(page, page.width + 16, page.height + 16)
        local washMax, gRight
        for _, o in ipairs(Recorder.ops) do
            local n = tostring(o.name or "")
            if (o.y or 99) < 20 then
                if n:find("wash", 1, true) then
                    washMax = math.max(washMax or 0, (o.x or 0) + (o.w or 0))
                elseif n == glyph then
                    gRight = (o.x or 0) + (o.w or 0)
                end
            end
        end
        return washMax, gRight
    end
    local washU, pinU = frameAndMeasure("sir_ui-pin")
    page.pin = true
    page.pinButton:setVisible(false)
    page.collapseButton:setVisible(true)
    local washP, pinP = frameAndMeasure("sir_ui-pin-off")
    return Assert.isTrue(pinU ~= nil, "pin glyph rendered unpinned")
        and Assert.isTrue(washU ~= nil and pinU ~= nil and washU >= pinU,
            "capsule extends under the pin button")
        and Assert.isTrue(pinP ~= nil, "pin-off glyph rendered while pinned")
        and Assert.isTrue(washP ~= nil and pinP ~= nil and washP >= pinP,
            "capsule extends under the pin-off button")
end

tests["weight_pill_carries_the_room_left_fill"] = function()
    -- the pill doubles as a capacity gauge in the DRAINABLE vocabulary: the
    -- fill is ROOM LEFT (long neutral bar = space; short warm bar = nearly
    -- full — same read as the fluid/battery row bars). 7.5 / 10 load ->
    -- room 0.25 -> ok tier, and the fill must span ~25% of the pill (a
    -- load-fraction fill would span ~75% — the "backwards" field report).
    local T = require "sir_theme"
    local page = SIRInv.build({})
    local oldLW, oldGSP = ISInventoryPage.loadWeight, getSpecificPlayer
    ISInventoryPage.loadWeight = function() return 7.5 end
    _G.getSpecificPlayer = function()
        return {
            getInventory = function() return page.inventoryPane.inventory end,
            getMaxWeight = function() return 10 end,
        }
    end
    local ok, err = pcall(function()
        Render.frame(page, page.width + 16, page.height + 16)
    end)
    ISInventoryPage.loadWeight = oldLW
    _G.getSpecificPlayer = oldGSP
    if not ok then error(err) end
    local cc = T.color.condition.ok
    local fMin, fMax, pMin, pMax
    for _, o in ipairs(Recorder.ops) do
        local n = tostring(o.name or "")
        -- pill wash tops at y=0; the fill rides INSIDE the track at y=2
        if (o.y or -1) <= 4 and (o.y or -1) >= 0 then
            if n:find("chip", 1, true)
                and math.abs((o.r or 0) - cc[1]) < 0.01
                and math.abs((o.g or 0) - cc[2]) < 0.01
                and math.abs((o.b or 0) - cc[3]) < 0.01 then
                fMin = math.min(fMin or o.x, o.x)
                fMax = math.max(fMax or 0, o.x + (o.w or 0))
            elseif n:find("wash", 1, true) then
                pMin = math.min(pMin or o.x, o.x)
                pMax = math.max(pMax or 0, o.x + (o.w or 0))
            end
        end
    end
    if not (fMin and pMin) then
        return Assert.isTrue(fMin ~= nil, "room-left fill chip painted (ok-tier tint)")
            and Assert.isTrue(pMin ~= nil, "pill wash painted")
    end
    -- the capsule now includes the pin seat chip, so 0.25 room reads as
    -- ~0.15 of the full span; a load-fraction regression would read ~0.45
    local ratio = (fMax - fMin) / math.max(1, pMax - pMin)
    return Assert.isTrue(ratio > 0.08 and ratio < 0.30,
        "fill spans ~room-left fraction of the capsule (got " .. tostring(ratio) .. ")")
end

tests["weight_pill_stays_on_the_rail_and_fill_stays_in_the_track"] = function()
    -- two field reports in one frame: (1) collapsed (rail-only, waiting to be
    -- hovered) the pill wash must not lip past the title bar; (2) at FULL
    -- room (a debug 0-weight session) the fill must sit inside the wash
    -- track with margins — a track-wide fill ran flush into the pin button.
    local T = require "sir_theme"
    local page = SIRInv.build({})
    page.isCollapsed = true
    local oldLW, oldGSP = ISInventoryPage.loadWeight, getSpecificPlayer
    ISInventoryPage.loadWeight = function() return 0 end
    _G.getSpecificPlayer = function()
        return {
            getInventory = function() return page.inventoryPane.inventory end,
            getMaxWeight = function() return 12 end,
        }
    end
    local ok, err = pcall(function()
        Render.frame(page, page.width + 16, page.height + 16)
    end)
    ISInventoryPage.loadWeight = oldLW
    _G.getSpecificPlayer = oldGSP
    if not ok then error(err) end
    local th = page:titleBarHeight()
    local cc = T.color.condition.good
    local onRail = true
    local fMin, fMax, pMin, pMax
    for _, o in ipairs(Recorder.ops) do
        local n = tostring(o.name or "")
        if (o.y or th) < th then
            if n:find("wash", 1, true) then
                pMin = math.min(pMin or o.x, o.x)
                pMax = math.max(pMax or 0, o.x + (o.w or 0))
                if (o.y or 0) + (o.h or 0) > th then onRail = false end
            elseif n:find("chip", 1, true)
                and math.abs((o.r or 0) - cc[1]) < 0.01
                and math.abs((o.g or 0) - cc[2]) < 0.01
                and math.abs((o.b or 0) - cc[3]) < 0.01 then
                fMin = math.min(fMin or o.x, o.x)
                fMax = math.max(fMax or 0, o.x + (o.w or 0))
                if (o.y or 0) + (o.h or 0) > th then onRail = false end
            end
        end
    end
    if not (fMin and pMin) then
        return Assert.isTrue(fMin ~= nil, "full-room fill painted (good-tier tint)")
            and Assert.isTrue(pMin ~= nil, "pill wash painted")
    end
    return Assert.isTrue(onRail, "pill + fill stay within the title bar when collapsed")
        and Assert.isTrue(fMin >= pMin + 2, "fill keeps the left track margin")
        and Assert.isTrue(fMax <= pMax - 2, "fill keeps the right track margin (was flush into the pin)")
end

tests["column_rules_follow_the_scroll_below_the_equipped_divider"] = function()
    -- rows + rules draw in CONTENT coordinates (the element transform applies
    -- the scroll), but the rules' bottom clamped to bare pane HEIGHT — a
    -- viewport measure. Scrolled down, the visible window is [-yScroll,
    -- -yScroll + H], so the rules died mid-list. Field report: "no gauge
    -- column line below the equipped divider" (equipped sorts last = the
    -- deepest content). Shrink the viewport, scroll deep enough that the
    -- equipped divider is on screen, and demand the status-lane rule extends
    -- past it.
    local T = require "sir_theme"
    local page = SIRInv.build({ equipped = true })
    local pane = page.inventoryPane
    pane.height = 200
    pane:setYScroll(-200)
    Render.frame(page, page.width + 16, page.height + 16)
    local ih = pane.itemHgt or 18
    local laneX = _G.SauceInvRender.rowGeom(ih).laneX
    local hr = T.ink.headRule
    local divY, ruleBot
    for _, o in ipairs(Recorder.ops) do
        if o.op == "rect" then
            if (o.h or 0) == 1 and (o.w or 0) > 100
                and math.abs((o.r or 0) - hr[1]) < 0.01
                and math.abs((o.g or 0) - hr[2]) < 0.01
                and math.abs((o.b or 0) - hr[3]) < 0.01
                and math.abs((o.a or 0) - hr[4]) < 0.01 then
                divY = o.y
            elseif (o.w or 0) == 1 and (o.h or 0) > 30 and o.x == laneX then
                ruleBot = math.max(ruleBot or 0, o.y + o.h)
            end
        end
    end
    return Assert.isTrue(divY ~= nil, "equipped divider rendered in the scrolled viewport")
        and Assert.isTrue(ruleBot ~= nil, "status-lane column rule rendered")
        and Assert.isTrue(ruleBot ~= nil and divY ~= nil and ruleBot >= divY + ih,
            "lane rule extends below the equipped divider (rule bottom "
            .. tostring(ruleBot) .. " vs divider " .. tostring(divY) .. ")")
end

return tests
