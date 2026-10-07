--[[
    Tooltip gauntlet: real item tooltips, rendered headless, read back.

    Tool:   tooltipGauntlet{ items = { { type = "Base.Axe", prep = "<lua>" }, ... },
                             detail = true|false, frames = 2 }
            prep: a Lua chunk run with `item` (and `player`) before the render,
                  to give the item state (VPS kills, a Stir genome, condition...)

    Every item goes through the REAL ISToolTipInv (vanilla) and the REAL Java
    ObjectTooltip, with whatever mods the VM loaded (lua_mods: TooltipLib and
    every other tooltip mod's hooks in the chain, in the game's load order).
    The game's fonts are loaded headless (PZEngine.loadFonts: the real .fnt
    metrics) and every string Java draws is recorded (PZEngine.textDraws: the
    game's AngelCodeFont plus a recorder). Each frame reports:
      panel      the ISToolTipInv's width x height
      strings    every string drawn, at its position relative to the panel
      outside    strings that fall outside the panel (a row the panel does not hold)
      overlaps   strings that overlap another on the same line
      errors     anything that threw during the render
    plus TooltipLib's own verdict (TooltipLib.diagnose) when it is loaded.
    Frame 1 records providers' content; frame 2 replays it (TooltipLib's cache),
    so both are checked. `detail` holds the detail key (Shift) for the run.

    Best on an MP client side booted with lua_mods (it has the game's globals
    and the full vanilla UI); docs/lua-mods.md.
]]

local try = WB.try

-- Measure with the GAME's text manager and font enum, the ones Java laid the
-- panel out with: on a bench client getTextManager / UIFont are uiview's Lua
-- stand-ins with their own metrics (they read a 205px line as 321px).
local function javaText()
    local gg = rawget(_G, "_pz_game_globals")
    local tm = gg and gg.getTextManager and gg.getTextManager()
    local font = zombie and zombie.ui and zombie.ui.UIFont and zombie.ui.UIFont.Small
    return tm, font
end
local function measure(text)
    local tm, font = javaText()
    local w = 0
    if tm and font then pcall(function() w = tm:MeasureStringX(font, text) end) end
    return w or 0
end

local function frame(panel, item)
    local errors = {}
    pcall(PZEngine.textRecord, true)
    local ok, err = pcall(function() panel:prerender() end)
    if not ok then errors[#errors + 1] = "prerender: " .. tostring(err) end
    ok, err = pcall(function() panel:render() end)
    if not ok then errors[#errors + 1] = "render: " .. tostring(err) end
    pcall(PZEngine.textRecord, false)
    local drawn = PZEngine.textDraws() or {}
    local px, py = 0, 0
    pcall(function() px, py = panel:getAbsoluteX(), panel:getAbsoluteY() end)
    local w, h = panel:getWidth(), panel:getHeight()
    local strings, outside, overlaps = {}, {}, {}
    local lineH = 14
    pcall(function() local tm, font = javaText(); lineH = tm:getFontHeight(font) end)
    for i, d in ipairs(drawn) do
        local x, y = math.floor(d.x - px + 0.5), math.floor(d.y - py + 0.5)
        local tw = measure(d.text)
        local s = { text = d.text, x = x, y = y, w = tw, r = d.r, g = d.g, b = d.b, a = d.a }
        strings[#strings + 1] = s
        if x < 0 or y < 0 or x + tw > w + 1 or y + lineH > h + 1 then outside[#outside + 1] = s end
    end
    for i = 1, #strings do
        for j = i + 1, #strings do
            local a, b = strings[i], strings[j]
            if a.text ~= "" and b.text ~= "" and math.abs(a.y - b.y) < lineH * 0.6
                and a.x < b.x + b.w and b.x < a.x + a.w then
                overlaps[#overlaps + 1] = { a = a.text, b = b.text, y = a.y }
            end
        end
    end
    return { panel = { w = w, h = h }, strings = strings, outside = outside, overlaps = overlaps, errors = errors }
end

WB.register("tooltipGauntlet", function(a)
    if not (PZEngine and PZEngine.loadFonts and PZEngine.textDraws) then error("needs engine mode (PZEngine.loadFonts / textDraws)", 0) end
    local fonts = PZEngine.loadFonts()
    if not ISToolTipInv then error("no ISToolTipInv (boot a client side with full vanilla UI)", 0) end
    local detail = a.detail == true
    local savedDetail = TooltipLib and TooltipLib._readDetailKey
    if TooltipLib then TooltipLib._readDetailKey = function() return detail end end
    local player = getPlayer and getPlayer()
    local report = { fonts = fonts, detail = detail, items = {} }
    for _, spec in ipairs(a.items or { { type = "Base.Axe" } }) do
        local entry = { type = spec.type }
        local item = try(function() return instanceItem(spec.type) end)
        if not item then
            entry.error = "no item " .. tostring(spec.type)
        else
            if player then pcall(function() player:getInventory():AddItem(item) end) end
            if spec.prep and spec.prep ~= "" then
                local chunk, cerr = (_pz_compile or loadstring)("local item, player = ...\n" .. spec.prep, "prep")
                local ok, perr = false, cerr
                if chunk then ok, perr = pcall(chunk, item, player) end
                if not ok then entry.prepError = tostring(perr) end
            end
            entry.name = try(function() return item:getDisplayName() end)
            local panel = try(function() local p = ISToolTipInv:new(item); p:initialise(); p:addToUIManager(); return p end)
            if not panel then
                entry.error = "ISToolTipInv:new failed"
            else
                entry.frames = {}
                for f = 1, math.max(1, tonumber(a.frames) or 2) do entry.frames[f] = frame(panel, item) end
                pcall(function() panel:removeFromUIManager() end)
            end
            if player then pcall(function() player:getInventory():Remove(item) end) end
        end
        report.items[#report.items + 1] = entry
    end
    if TooltipLib then
        TooltipLib._readDetailKey = savedDetail
        local ok, d, level, summary = pcall(TooltipLib.diagnose, true)
        if ok then report.tooltipLib = { level = level, summary = summary, report = type(d) == "string" and d or nil } end
    end
    return report
end)
