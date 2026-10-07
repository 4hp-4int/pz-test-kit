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

-- the panel dress (TooltipLib.setPanelDress: SauceTooltips' chrome): whether it
-- drew this frame, at what size, and where its gauges went
local function watchDress()
    local seen = { draws = {}, ornaments = {} }
    if not TooltipLib then return seen, function() end end
    local d0, o0 = TooltipLib._drawPanelDress, TooltipLib._drawPanelOrnaments
    if d0 then
        TooltipLib._drawPanelDress = function(spec, panel, tooltip, w, h, surface, accent)
            local r = d0(spec, panel, tooltip, w, h, surface, accent)
            if r then seen.draws[#seen.draws + 1] = { id = spec and spec.id, w = w, h = h } end
            return r
        end
    end
    if o0 then
        TooltipLib._drawPanelOrnaments = function(spec, panel, tooltip, geom, surface, accent)
            local r = o0(spec, panel, tooltip, geom, surface, accent)
            if r and type(geom) == "table" then
                local bars, maxY = 0, 0
                for _, row in ipairs(geom.rows or {}) do
                    if row.kind == "bar" then bars = bars + 1 end
                    if (row.y or 0) > maxY then maxY = row.y end
                end
                seen.ornaments[#seen.ornaments + 1] = { id = spec and spec.id, rows = #(geom.rows or {}), bars = bars, maxY = maxY,
                    band = (geom.valueRightX and geom.midX) and (geom.valueRightX - geom.midX) or nil }
            end
            return r
        end
    end
    return seen, function() TooltipLib._drawPanelDress, TooltipLib._drawPanelOrnaments = d0, o0 end
end

-- Every texture/rect draw a frame makes, on both surfaces a dress paints on:
-- the Java ObjectTooltip (Lua->Java calls go through its class metatable) and
-- the Lua panel (ISToolTipInv, an instance). Headless the textures never draw
-- pixels (they stay "loading", as in game), so this is what reads the dress.
local DRAWS = { "DrawTexture", "DrawTextureScaled", "DrawTextureScaledColor", "DrawTextureScaledAspect", "DrawTextureColor",
                "DrawTextureScaledUniform", "DrawRect", "DrawRectBorder", "DrawTextureAngle",
                "drawTexture", "drawTextureScaled", "drawTextureScaledColor", "drawTextureScaledAspect", "drawTextureScaledUniform",
                "drawRect", "drawRectBorder", "drawTextureAllPoint", "drawTextureTiled", "drawTextureTiledX", "drawTextureTiledY" }
local function texName(t)
    if type(t) ~= "userdata" and type(t) ~= "table" then return nil end
    local n
    pcall(function() n = t:getName() end)
    return n
end
local function watchDraws(panel, tooltip)
    local rec, undo = {}, {}
    local function record(surface, fn, args)
        local tex, nums = nil, {}
        for _, v in ipairs(args) do
            if tex == nil then tex = texName(v) end
            if type(v) == "number" then nums[#nums + 1] = v end
        end
        rec[#rec + 1] = { surface = surface, fn = fn, tex = tex, x = nums[1], y = nums[2], w = nums[3], h = nums[4] }
    end
    -- the Java tooltip: its class's metatable
    local cm = rawget(_G, "__classmetatables")
    local cls = tooltip and cm and (function() local c; pcall(function() c = tooltip:getClass() end); return c end)()
    local mt = cls and cm[cls]
    local idx = mt and type(mt.__index) == "table" and mt.__index
    if idx then
        for _, fn in ipairs(DRAWS) do
            local orig = rawget(idx, fn)
            if type(orig) == "function" then
                rawset(idx, fn, function(self, ...) if self == tooltip then record("tooltip", fn, { ... }) end return orig(self, ...) end)
                undo[#undo + 1] = function() rawset(idx, fn, orig) end
            end
        end
    end
    -- the Lua panel: its methods (the instance shadows the class while watched)
    for _, fn in ipairs(DRAWS) do
        local orig = panel[fn]
        if type(orig) == "function" and rawget(panel, fn) == nil then
            panel[fn] = function(self, ...) record("panel", fn, { ... }) return orig(self, ...) end
            undo[#undo + 1] = function() panel[fn] = nil end
        end
    end
    return rec, function() for _, u in ipairs(undo) do u() end end
end

local function frame(panel, item)
    local errors = {}
    local dress, unwatch = watchDress()
    local draws, unwatchDraws = watchDraws(panel, panel.tooltip)
    pcall(PZEngine.textRecord, true)
    local ok, err = pcall(function() panel:prerender() end)
    if not ok then errors[#errors + 1] = "prerender: " .. tostring(err) end
    ok, err = pcall(function() panel:render() end)
    if not ok then errors[#errors + 1] = "render: " .. tostring(err) end
    pcall(PZEngine.textRecord, false)
    unwatch()
    unwatchDraws()
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
    -- the dress must be drawn at the panel's own size (a dress sized to another
    -- pass is a frame around nothing, or content outside the frame)
    local dressMismatch = {}
    for _, d in ipairs(dress.draws) do
        if math.abs((d.w or 0) - w) > 1 or math.abs((d.h or 0) - h) > 1 then dressMismatch[#dressMismatch + 1] = d end
    end
    -- the dress's own pieces: SauceTooltips' nine-patch (st_*) and any other named texture
    local pieces, box = {}, nil
    for _, d in ipairs(draws) do
        if d.tex then
            pieces[d.tex] = (pieces[d.tex] or 0) + 1
            if d.tex:find("^st_") and d.x and d.y and d.w and d.h then
                box = box or { x1 = d.x, y1 = d.y, x2 = d.x + d.w, y2 = d.y + d.h }
                box.x1, box.y1 = math.min(box.x1, d.x), math.min(box.y1, d.y)
                box.x2, box.y2 = math.max(box.x2, d.x + d.w), math.max(box.y2, d.y + d.h)
            end
        end
    end
    return { panel = { w = w, h = h }, strings = strings, outside = outside, overlaps = overlaps, errors = errors,
             draws = { count = #draws, textures = pieces, dressBox = box },
             dress = { draws = dress.draws, ornaments = dress.ornaments, mismatch = dressMismatch,
                       active = TooltipLib and TooltipLib._panelDress and TooltipLib._panelDress.id or nil } }
end

WB.register("tooltipGauntlet", function(a)
    if not (PZEngine and PZEngine.loadFonts and PZEngine.textDraws) then error("needs engine mode (PZEngine.loadFonts / textDraws)", 0) end
    local fonts = PZEngine.loadFonts()
    -- the game's textures, headless (the dress resolves its nine-patch; draws are recorded)
    if PZEngine.loadTextures then pcall(PZEngine.loadTextures, {}) end
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
