--[[
    UIView — Headless ISUI mock
    ===========================
    Clean-room, API-compatible reimplementation of the slice of PZ's ISUI layer
    that real mod panels actually call. Draw methods carry VANILLA-EXACT
    signatures (note drawRect takes alpha FIRST: drawRect(x,y,w,h, a,r,g,b)) and
    route every primitive into UIView/Recorder in screen coordinates.

    Because the signatures match vanilla, a real mod panel's :render() runs here
    unchanged — it just paints into a display list instead of the GL surface.

    Globals installed (matching the names panels reference):
        ISBaseObject, ISUIElement, ISPanel, ISButton, ISLabel
        UIFont, getCore(), getTextManager(), UIManager
        getMouseX/getMouseY + UIView_setMouse() to drive hit-tests

    Fidelity caveats:
      - Text width is EXACT for ASCII: per-glyph advances generated from PZ's
        own .fnt files (UIView/FontMetrics.lua). Non-ASCII falls back to the
        font's mean advance. Pick the size with UIView_setFontSize("1x".."4x").
      - Textures are recorded by name as placeholder boxes (no pixels headless).
]]

local Recorder = require "UIView/Recorder"

-- ── Screen + core stubs ─────────────────────────────────────────────────────
local SCREEN_W, SCREEN_H = 1920, 1080

local _core = {
    getScreenWidth  = function(self) return SCREEN_W end,
    getScreenHeight = function(self) return SCREEN_H end,
    -- Mirrors the modelled size directory, so anything reading the option
    -- agrees with what MeasureStringX is actually using.
    getOptionFontSizeReal = function(self)
        local d = _G.UIView_getFontSize and _G.UIView_getFontSize() or "2x"
        return ({ ["1x"] = 2, ["2x"] = 3, ["3x"] = 4, ["4x"] = 5 })[d] or 3
    end,
    -- used by the real ISInventoryPage chrome
    getOptionInventoryContainerSize = function(self) return 1 end,
    getGameMode = function(self) return "Survivor" end,
    getGoodHighlitedColor = function(self) return { getR = function() return 0.98 end, getG = function() return 0.56 end, getB = function() return 0.11 end } end,
}
function getCore() return _core end
function UIView_setScreen(w, h) SCREEN_W, SCREEN_H = w, h end

-- ── Fonts + text measurement ────────────────────────────────────────────────
-- Per-font metrics approximation. height is line height; charW is the average
-- advance width used by MeasureStringX. These are eyeballed from PZ's bitmap
-- fonts and are the main knob for layout fidelity.
UIFont = {
    Small      = "Small",
    Medium     = "Medium",
    Large      = "Large",
    Massive    = "Massive",
    NewSmall   = "NewSmall",
    NewMedium  = "NewMedium",
    NewLarge   = "NewLarge",
    MediumNew  = "MediumNew",
    Title      = "Title",
    Cred1      = "Cred1",
    Code       = "Code",
    AutoNormSmall  = "Small",
    AutoNormMedium = "Medium",
    AutoNormLarge  = "Large",
}

-- REAL PER-GLYPH METRICS, generated from PZ's own .fnt files. See
-- UIView/FontMetrics.lua and uiview/tools/gen_font_metrics.py.
--
-- The table below is the LEGACY average-width fallback, kept only for the case
-- where the generated file is absent (a checkout that has never run the
-- generator). It is what every preview used to flow on, and the reason a
-- wrapped paragraph could look comfortable in the mock and run off the card in
-- the game: an average is right for a random string and wrong for every
-- specific one, and the error accumulates with length.
local FONT = {
    Small     = { h = 14, w = 6.2 },
    Medium    = { h = 18, w = 8.0 },
    Large     = { h = 24, w = 11.0 },
    Massive   = { h = 36, w = 17.0 },
    NewSmall  = { h = 14, w = 6.2 },
    NewMedium = { h = 18, w = 8.0 },
    NewLarge  = { h = 24, w = 11.0 },
    MediumNew = { h = 18, w = 8.0 },
    Title     = { h = 28, w = 13.0 },
    Cred1     = { h = 20, w = 9.0 },
    Code      = { h = 14, w = 7.0 },
}

-- Global font scale (models the in-game UI font-size option: fixed-pixel
-- layouts that ignore it are a real bug class -- see SIR's metrics tokens).
-- Scenes set it via PZTestKit-style: UIMock_setFontScale(1.8); modules that
-- cache metrics must refresh after (e.g. sir_theme's T.metricsRefresh()).
local _fontScale = 1
function _G.UIMock_setFontScale(s) _fontScale = s or 1 end
function _G.UIMock_getFontScale() return _fontScale end

local METRICS = nil
pcall(function() METRICS = require "UIView/FontMetrics" end)

-- Which of PZ's four font-size directories to model. The game picks this from
-- the font-size option (TextManager.java:207) -- 2->1x, 3->2x, 4->3x, 5->4x --
-- so judging a layout at the wrong one is judging someone else's screen.
local _sizeDir = "2x"
function _G.UIView_setFontSize(dir) _sizeDir = dir or "2x" end
function _G.UIView_getFontSize() return _sizeDir end

--- Exact width, matching AngelCodeFont.getWidth(text, 0, len-1, false):
--- advances for every glyph except the last, which contributes its ink WIDTH,
--- and unknown codepoints contribute nothing at all.
local function exactWidth(font, str)
    local set = METRICS and METRICS[_sizeDir]
    local m = set and (set[font] or set.Small)
    if not m then return nil end

    local s = tostring(str)
    local n = #s
    local w, maxw = 0, 0
    for i = 1, n do
        local cp = s:byte(i)
        if cp == 10 then
            w = 0
        else
            local a = m.adv[cp]
            if a then
                if i == n then
                    w = w + (m.wid[cp] or a)
                else
                    w = w + a
                end
            elseif cp >= 128 then
                -- Outside the generated ASCII range (CJK / Cyrillic): the mean
                -- advance, so those previews stay approximate rather than wrong
                -- by the whole string.
                w = w + m.fallback
            end
            if w > maxw then maxw = w end
        end
    end
    return math.floor(maxw * _fontScale + 0.5)
end
--- Baseline offset for a font at the modelled size, or nil when the generated
--- metrics are unavailable.
local function fontBase(font)
    local set = METRICS and METRICS[_sizeDir]
    local m = set and (set[font] or set.Small)
    if not m or not m.base then return nil end
    return math.floor(m.base * _fontScale + 0.5)
end

local function fontMetrics(font)
    local set = METRICS and METRICS[_sizeDir]
    local real = set and (set[font] or set.Small)
    if real then
        local h = real.h
        if _fontScale ~= 1 then h = math.floor(h * _fontScale + 0.5) end
        -- `w` is kept for the handful of callers that still want an average
        -- glyph; nothing that flows a layout should use it.
        return { h = h, w = real.fallback * _fontScale }
    end
    local m = FONT[font] or FONT.Small
    if _fontScale == 1 then return m end
    return { h = math.floor(m.h * _fontScale + 0.5), w = m.w * _fontScale }
end

local _textManager = {
    MeasureStringX = function(self, font, str)
        if not str then return 0 end
        return exactWidth(font, str)
            or math.floor(#tostring(str) * fontMetrics(font).w + 0.5)
    end,
    MeasureStringY = function(self, font, str)
        return fontMetrics(font).h
    end,
    getFontHeight = function(self, font)
        return fontMetrics(font).h
    end,
    MeasureFont = function(self, font)
        return fontMetrics(font).h
    end,
}
function getTextManager() return _textManager end

-- ── Mouse state (for input injection / hit-tests) ───────────────────────────
local _mouseX, _mouseY = -1, -1
function getMouseX() return _mouseX end
function getMouseY() return _mouseY end
function UIView_setMouse(x, y) _mouseX, _mouseY = x, y end

-- ── UIManager stub ──────────────────────────────────────────────────────────
UIManager = {
    AddUI = function(j) end,
    RemoveElement = function(j) end,
    getMillisSinceLastRender = function() return 16 end,
    setShowPausedMessage = function(b) end,
}

-- ── Color helper ────────────────────────────────────────────────────────────
local function rgba(r, g, b, a)
    return {
        r = r or 1, g = g or 1, b = b or 1, a = a == nil and 1 or a,
    }
end

-- ============================================================================
-- ISBaseObject
-- ============================================================================
ISBaseObject = {}
ISBaseObject.Type = "ISBaseObject"

function ISBaseObject:derive(typeName)
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o.Type = typeName
    return o
end

function ISBaseObject:new()
    local o = setmetatable({}, self)
    self.__index = self
    return o
end

function ISBaseObject:getType() return self.Type end

-- ============================================================================
-- ISUIElement
-- ============================================================================
local _nextId = 1

ISUIElement = ISBaseObject:derive("ISUIElement")

function ISUIElement:new(x, y, width, height)
    local o = setmetatable({}, self)
    self.__index = self
    o.x = x or 0
    o.y = y or 0
    o.width = width or 0
    o.height = height or 0
    o.anchorLeft, o.anchorTop = true, true
    o.anchorRight, o.anchorBottom = false, false
    o._visible = true
    o.children = {}
    o.childrenInOrder = {}
    o.parent = nil
    o._uid = _nextId; _nextId = _nextId + 1
    return o
end

function ISUIElement:initialise()
    self.children = self.children or {}
    self.childrenInOrder = self.childrenInOrder or {}
end

--- Vanilla's instantiate() builds the Java object AND calls createChildren()
--- (ISUIElement.lua:1007). The mock's was a no-op, so a real panel mounted here
--- only got the children the SCENE built by hand, and nothing nested ever built
--- its own -- which is why a viewport's scroll bar simply did not exist in the
--- preview while the game had one taking 17px off the content column.
--- Guarded, because addChild instantiates too and a panel may be added twice.
function ISUIElement:instantiate()
    if self._instantiated then return end
    self._instantiated = true
    self:createChildren()
end
function ISUIElement:createChildren() end

-- geometry --------------------------------------------------------------------
function ISUIElement:getX() return self.x end
function ISUIElement:getY() return self.y end
function ISUIElement:getWidth() return self.width end
function ISUIElement:getHeight() return self.height end
function ISUIElement:setX(x) self.x = x end
function ISUIElement:setY(y) self.y = y end
function ISUIElement:setWidth(w) self.width = w end
-- Vanilla anchors the scroll bar to its parent's bottom, so the Java side
-- resizes it whenever the parent does. Without mirroring that, a viewport that
-- is resized after construction previews with a bar running past the bottom of
-- the card it belongs to.
function ISUIElement:setHeight(h)
    self.height = h
    if self.vscroll then self.vscroll.height = h end
end
function ISUIElement:getRight() return self.x + self.width end
function ISUIElement:getBottom() return self.y + self.height end
function ISUIElement:getCenterX() return self.x + self.width / 2 end
function ISUIElement:getCenterY() return self.y + self.height / 2 end
function ISUIElement:setCenterX(x) self.x = x - self.width / 2 end
function ISUIElement:setCenterY(y) self.y = y - self.height / 2 end

function ISUIElement:getAbsoluteX()
    if self.parent then return self.parent:getAbsoluteX() + self.x end
    return self.x
end
function ISUIElement:getAbsoluteY()
    if self.parent then return self.parent:getAbsoluteY() + self.y end
    return self.y
end

function ISUIElement:getXScroll() return 0 end
function ISUIElement:getYScroll() return 0 end
function ISUIElement:getScrollX() return 0 end
function ISUIElement:getScrollY() return 0 end

function ISUIElement:setVisible(v) self._visible = v and true or false end
function ISUIElement:isVisible() return self._visible end
function ISUIElement:isReallyVisible() return self._visible end
function ISUIElement:setEnabled(e) self.enabled = e end
function ISUIElement:isEnabled() return self.enabled ~= false end

function ISUIElement:setAnchorLeft(b) self.anchorLeft = b end
function ISUIElement:setAnchorRight(b) self.anchorRight = b end
function ISUIElement:setAnchorTop(b) self.anchorTop = b end
function ISUIElement:setAnchorBottom(b) self.anchorBottom = b end

function ISUIElement:getMouseX() return getMouseX() - self:getAbsoluteX() end
function ISUIElement:getMouseY() return getMouseY() - self:getAbsoluteY() end

function ISUIElement:isPointOver(sx, sy)
    local ax, ay = self:getAbsoluteX(), self:getAbsoluteY()
    return sx >= ax and sx < ax + self.width and sy >= ay and sy < ay + self.height
end
function ISUIElement:isMouseOver()
    return self:isPointOver(getMouseX(), getMouseY())
end
function ISUIElement:containsPoint(x, y)
    return x >= self.x and x < self.x + self.width and y >= self.y and y < self.y + self.height
end

-- tree ------------------------------------------------------------------------
function ISUIElement:addChild(child)
    if child.children == nil then child.children = {}; child.childrenInOrder = {} end
    child.parent = self
    -- Vanilla instantiates an added child (ISUIElement.lua:1455), which is what
    -- gives it its own children.
    if child.instantiate then child:instantiate() end
    self.children[child._uid or (#self.childrenInOrder + 1)] = child
    table.insert(self.childrenInOrder, child)
    return child
end
function ISUIElement:removeChild(child)
    for i = #self.childrenInOrder, 1, -1 do
        if self.childrenInOrder[i] == child then table.remove(self.childrenInOrder, i) end
    end
    if child._uid then self.children[child._uid] = nil end
    child.parent = nil
end
function ISUIElement:clearChildren()
    self.children = {}
    self.childrenInOrder = {}
end
function ISUIElement:getParent() return self.parent end
function ISUIElement:getChildren() return self.children end
function ISUIElement:getChildrenInOrder() return self.childrenInOrder end

-- addToUIManager stashes the element globally so scenes can grab panels created
-- inside a mod's own (locally-scoped) install hook — e.g. TooltipLib's
-- WorldObjectPanel, which is a file-local with no other handle.
function ISUIElement:addToUIManager() self._inManager = true; _G.UIView_lastAddedUI = self end
function ISUIElement:removeFromUIManager() self._inManager = false; self.removed = true end
function ISUIElement:setAlwaysOnTop(b) self._alwaysOnTop = b end
function ISUIElement:setKeepOnScreen(b) self.keepOnScreen = b end
function ISUIElement:bringToTop() end
function ISUIElement:ignoreWidthChange() end
function ISUIElement:ignoreHeightChange() end

-- lifecycle (no-ops on the base; subclasses/mods override) --------------------
function ISUIElement:update() end
function ISUIElement:prerender() end
function ISUIElement:render() end

-- ── DRAW PRIMITIVES → RECORDER (vanilla-exact signatures) ───────────────────
-- All take element-local coords; we add the element's absolute origin so the
-- recorded op is in screen space.
--
-- SCROLL TRANSFORM (matches PZ's java UIElement): ordinary draws shift by the
-- DRAWING element's own X/YScroll -- that's how row content scrolls inside a
-- pane. The *Static variants do NOT shift: they're vanilla's pinning mechanism
-- for in-pane chrome (header strips, backdrops). Children are screen-space
-- (vanilla counter-offsets contextButtons by +getYScroll to FOLLOW content,
-- which proves they don't inherit the transform). This gap hid SIR's
-- band-rides-the-scroll bug: perfect in harness, broken in game.

local function scrollXY(self)
    return (self.getXScroll and self:getXScroll() or 0),
           (self.getYScroll and self:getYScroll() or 0)
end

-- clip an op to the element's active stencil (absolute coords). Returns
-- nil,nil to DROP, else the clipped y,h (x/w pass through: vertical scroll is
-- the case that matters; horizontal clipping can join when something needs it)
local function clipY(self, y, h)
    local st = self._stencil
    if not st or self._stencilOff then return y, h end
    local top, bot = st.y, st.y + st.h
    local y2 = y + (h or 0)
    if y2 <= top or y >= bot then return nil, nil end
    if y < top then h = h - (top - y); y = top end
    if y + h > bot then h = bot - y end
    return y, h
end

local function pushRect(self, op, x, y, w, h, a, r, g, b, static)
    local c = rgba(r, g, b, a)
    local sx, sy = 0, 0
    if not static then sx, sy = scrollXY(self) end
    local ay, ah = clipY(self, self:getAbsoluteY() + y + sy, h)
    if not ay then return end
    Recorder.push({ op = op, x = self:getAbsoluteX() + x + sx, y = ay,
        w = w, h = ah, r = c.r, g = c.g, b = c.b, a = c.a, el = self._uid })
end

function ISUIElement:drawRect(x, y, w, h, a, r, g, b)
    if self.isCollapsed then return end
    pushRect(self, "rect", x, y, w, h, a, r, g, b, false)
end
function ISUIElement:drawRectStatic(x, y, w, h, a, r, g, b)
    if self.isCollapsed then return end
    pushRect(self, "rect", x, y, w, h, a, r, g, b, true)
end

function ISUIElement:drawRectBorder(x, y, w, h, a, r, g, b)
    pushRect(self, "rectborder", x, y, w, h, a, r, g, b, false)
end
function ISUIElement:drawRectBorderStatic(x, y, w, h, a, r, g, b)
    pushRect(self, "rectborder", x, y, w, h, a, r, g, b, true)
end

local function pushText(self, str, x, y, r, g, b, a, font, align, static)
    if self.isCollapsed or str == nil then return end
    local c = rgba(r, g, b, a)
    local sx, sy = 0, 0
    if not static then sx, sy = scrollXY(self) end
    -- text clips STRICTLY: real GL crops glyph pixels at the stencil edge; the
    -- mock can't render half-letters, so a line that CROSSES the edge drops
    -- entirely (poking out would paint into neighbouring bands -- it did)
    local st = self._stencil
    if st and not self._stencilOff then
        local ty = self:getAbsoluteY() + y + sy
        local fh = fontMetrics(font or UIFont.Small).h
        if ty < st.y or ty + fh > st.y + st.h then return end
    end
    local f = font or UIFont.Small
    Recorder.push({ op = "text", str = tostring(str),
        x = self:getAbsoluteX() + x + sx, y = self:getAbsoluteY() + y + sy,
        r = c.r, g = c.g, b = c.b, a = c.a,
        -- The PZ-exact width of this string. The viewer draws in a browser
        -- monospace face, so without it the picture is drawn at one width while
        -- the layout was computed at another -- which is how a line can look
        -- like it overflows a card in the preview and fit perfectly in game.
        mw = exactWidth(f, str),
        -- PZ's real line height for this font at the modelled size. The viewer
        -- used a hardcoded px per font name, which at 2x meant drawing 12px
        -- glyphs into a 26px line box -- small text in a big row, and a large
        -- letter-spacing correction to make up the width.
        fh = fontMetrics(f).h,
        -- Distance from the top of the line box down to the baseline. Lets the
        -- viewer place glyphs vertically where PZ places them rather than where
        -- a browser font happens to sit -- without it a strike-through rendered
        -- as an underline, which reads as a link, not as "this is over".
        fb = fontBase(f),
        font = f, align = align, el = self._uid })
end

function ISUIElement:drawText(str, x, y, r, g, b, a, font)
    pushText(self, str, x, y, r, g, b, a, font, "left", false)
end
ISUIElement.drawTextUntrimmed = ISUIElement.drawText
function ISUIElement:drawTextStatic(str, x, y, r, g, b, a, font)
    pushText(self, str, x, y, r, g, b, a, font, "left", true)
end
function ISUIElement:drawTextCentre(str, x, y, r, g, b, a, font)
    pushText(self, str, x, y, r, g, b, a, font, "centre", false)
end
function ISUIElement:drawTextCentreStatic(str, x, y, r, g, b, a, font)
    pushText(self, str, x, y, r, g, b, a, font, "centre", true)
end
function ISUIElement:drawTextRight(str, x, y, r, g, b, a, font)
    pushText(self, str, x, y, r, g, b, a, font, "right", false)
end
function ISUIElement:drawTextRightStatic(str, x, y, r, g, b, a, font)
    pushText(self, str, x, y, r, g, b, a, font, "right", true)
end

function ISUIElement:drawTextZoomed(str, x, y, zoom, r, g, b, a, font)
    pushText(self, str, x, y, r, g, b, a, font, "left", false)
end

local function pushTexture(self, name, x, y, w, h, a, r, g, b, static)
    local c = rgba(r, g, b, a)
    local sx, sy = 0, 0
    if not static then sx, sy = scrollXY(self) end
    local ay, ah = clipY(self, self:getAbsoluteY() + y + sy, h or 0)
    if not ay then return end
    Recorder.push({ op = "texture", name = name and tostring(name) or "",
        x = self:getAbsoluteX() + x + sx, y = ay, w = w or 0, h = ah,
        r = c.r, g = c.g, b = c.b, a = c.a, el = self._uid })
end

function ISUIElement:drawTextureScaled(tex, x, y, w, h, a, r, g, b)
    pushTexture(self, tex, x, y, w, h, a, r, g, b, false)
end
ISUIElement.drawTextureScaledColor = ISUIElement.drawTextureScaled
-- VANILLA-FAITHFUL MISNOMER: ISUIElement:drawTextureScaledStatic passes RAW
-- coords to the java draw -- it does NOT pin against scroll (drawRectStatic
-- does, by subtracting the scroll). Modeling the truth means a mod that
-- trusts the name fails HERE instead of in-game. Pin textures by
-- pre-subtracting the scroll yourself (see SIR's Chrome.nineStatic).
ISUIElement.drawTextureScaledStatic = ISUIElement.drawTextureScaled
function ISUIElement:drawTexture(tex, x, y, a, r, g, b)
    -- unknown native size; record a small marker box. Mods that need real size
    -- use drawTextureScaled.
    pushTexture(self, tex, x, y, 32, 32, a, r, g, b, false)
end
function ISUIElement:drawTextureStatic(tex, x, y, a, r, g, b)
    -- vanilla: pins ONLY the colored variant; the nil-color path is raw.
    -- Model the pinning variant (SIR passes colors).
    pushTexture(self, tex, x, y, 32, 32, a, r, g, b, r ~= nil)
end
function ISUIElement:drawTextureScaledAspect(tex, x, y, w, h, a, r, g, b)
    pushTexture(self, tex, x, y, w, h, a, r, g, b, false)
end

-- Vanilla's own tiler (UIElement.DrawTextureTiled). It differs from a loop of
-- drawTextureScaled in the one way that matters: the partial tile at the far
-- edge is CROPPED from the source, not squashed into the remainder. Recorded
-- as its own op so the replayer can use a canvas pattern and reproduce that,
-- rather than us re-implementing the loop here and inheriting whichever
-- behaviour we happened to write.
--
-- Note the argument order: (r, g, b, a), unlike drawTextureScaled's
-- (a, r, g, b). Getting this wrong tints everything and is easy to miss.
function ISUIElement:drawTextureTiled(tex, x, y, w, h, r, g, b, a)
    local c = rgba(r, g, b, a)
    local sx, sy = scrollXY(self)
    local ay, ah = clipY(self, self:getAbsoluteY() + y + sy, h or 0)
    if not ay then return end
    Recorder.push({ op = "texture_tiled", name = tex and tostring(tex) or "",
        x = self:getAbsoluteX() + x + sx, y = ay, w = w or 0, h = ah,
        -- The source rows already scrolled past are skipped by clipY, so the
        -- pattern has to start from the same phase the untruncated draw would.
        oy = ah - (h or 0),
        r = c.r, g = c.g, b = c.b, a = c.a, el = self._uid })
end
ISUIElement.drawTextureTiledX = ISUIElement.drawTextureTiled
ISUIElement.drawTextureTiledY = ISUIElement.drawTextureTiled

function ISUIElement:drawItemIcon(item, x, y, a, w, h)
    local name = "item"
    if item and item.getName then local ok, n = pcall(function() return item:getName() end); if ok and n then name = n end end
    local sx, sy = scrollXY(self)
    local ay, ah = clipY(self, self:getAbsoluteY() + y + sy, h or 32)
    if not ay then return end
    Recorder.push({ op = "itemicon", name = name,
        x = self:getAbsoluteX() + x + sx, y = ay, w = w or 32, h = ah,
        a = a == nil and 1 or a, el = self._uid })
end

-- stencil: modeled as a GL scissor on the DRAWING element (vanilla panes
-- clip their scrolled rows with it -- a no-op here let rows paint past the
-- viewport, which the live bridge made very visible)
function ISUIElement:setScrollWithParent(b) self._scrollWithParent = b end
function ISUIElement:setStencilRect(x, y, w, h)
    self._stencil = { x = self:getAbsoluteX() + (x or 0), y = self:getAbsoluteY() + (y or 0),
                      w = w or 0, h = h or 0 }
end
function ISUIElement:clearStencilRect() self._stencil = nil end
function ISUIElement:suspendStencil() self._stencilOff = true end
function ISUIElement:resumeStencil() self._stencilOff = false end
function ISUIElement:repaintStencilRect() end
function ISUIElement:updateScrollbars() end
function ISUIElement:setScrollHeight(h) self._scrollHeight = h or 0 end
function ISUIElement:getScrollHeight() return self._scrollHeight or 0 end
function ISUIElement:setYScroll(y) self._yScroll = y or 0 end
function ISUIElement:getIsVisible() return self._visible ~= false end

--- Vanilla adds a real ISScrollBar child here. Modelling it MATTERS: the bar
--- occupies a 17px column on the right of the element, so a preview without one
--- shows content in space the game does not have -- which is how a lore column
--- looked fine in the mock and ran under the scroll bar in the game. It also
--- makes the bar visible to a mod that reskins it, so chrome can be judged.
function ISUIElement:addScrollBars(addHorizontal)
    if self.vscroll then return end
    local bar = ISScrollBar:new(self, true)
    bar:initialise()
    self:addChild(bar)
    self.vscroll = bar
end
function ISUIElement:removeScrollBars()
    self.vscroll = nil
end
function ISUIElement:isVScrollBarVisible()
    return self.vscroll ~= nil and (self._scrollHeight or 0) > (self.height or 0)
end
function ISUIElement:setScrollWidth() end
-- (getScrollHeight lives with setScrollHeight above; a second stub here
-- returned 0 forever and made every scroll bar invisible.)
function ISUIElement:getScrollWidth() return 0 end

-- ============================================================================
-- ISInventoryItem — vanilla draws item icons through this; SIR hooks its
-- renderItemIcon to overlay condition bars. Provide it as a global table so
-- sir_icon_overlay can install its hook, and draw the item texture so icons
-- appear in headless inventory renders. (pane, item, x, y, alpha, w, h)
ISInventoryItem = ISInventoryItem or {}
function ISInventoryItem.renderItemIcon(pane, item, x, y, a, w, h)
    local tex = item and item.getTex and item:getTex()
    if tex and pane and pane.drawTextureScaledAspect then
        pane:drawTextureScaledAspect(tex, x, y, w or 32, h or 32, a or 1, 1, 1, 1)
    end
end

-- ============================================================================
-- ISPanel
-- ============================================================================
ISPanel = ISUIElement:derive("ISPanel")

function ISPanel:new(x, y, width, height)
    local o = ISUIElement.new(self, x, y, width, height)
    o.background = true
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.8 }
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    o.anchorLeft, o.anchorTop = true, true
    o.moveWithMouse = false
    return o
end

function ISPanel:prerender()
    if self.background then
        local bc = self.backgroundColor
        self:drawRect(0, 0, self.width, self.height, bc.a, bc.r, bc.g, bc.b)
    end
    if self.border ~= false then
        local b = self.borderColor
        self:drawRectBorder(0, 0, self.width, self.height, b.a, b.r, b.g, b.b)
    end
end

function ISPanel:setBackgroundColor(r, g, b, a) self.backgroundColor = { r = r, g = g, b = b, a = a } end
function ISPanel:setBorderColor(r, g, b, a) self.borderColor = { r = r, g = g, b = b, a = a } end
function ISPanel:setBackgroundRGBA(r, g, b, a) self.backgroundColor = { r = r, g = g, b = b, a = a } end

-- ============================================================================
-- ISButton
-- ============================================================================
ISButton = ISUIElement:derive("ISButton")

function ISButton:new(x, y, width, height, title, target, onclick)
    local o = ISUIElement.new(self, x, y, width, height)
    o.title = title or ""
    o.target = target
    o.onclick = onclick
    o.backgroundColor = { r = 0.15, g = 0.15, b = 0.15, a = 0.85 }
    o.backgroundColorMouseOver = { r = 0.3, g = 0.3, b = 0.3, a = 0.9 }
    o.borderColor = { r = 0.5, g = 0.5, b = 0.5, a = 1 }
    o.textColor = { r = 1, g = 1, b = 1, a = 1 }
    o.font = UIFont.Small
    o.enable = true
    return o
end

function ISButton:setOnClick(fn, target) self.onclick = fn; self.target = target end
function ISButton:setTitle(t) self.title = t end
function ISButton:setImage(tex) self.image = tex end
function ISButton:setEnable(b) self.enable = b end
function ISButton:setWidthToTitle(min)
    local w = getTextManager():MeasureStringX(self.font, self.title) + 20
    self.width = math.max(w, min or 0)
end

-- VANILLA SPLIT, and it matters. ISButton draws its BACKGROUND and BORDER in
-- prerender (gated on displayBackground) and its IMAGE/LABEL in render. A mod
-- that reskins a button replaces prerender -- that is the documented seam, and
-- it is what VPS's Chrome.dressButton does.
--
-- This mock used to draw all three in prerender, so a dressed button previewed
-- with NO LABEL: the reskin looked like it had eaten the text. The bug was
-- entirely in the mock, and it would have sent someone hunting through the
-- chrome code for a fault that was never there.
function ISButton:prerender()
    if self.displayBackground == false then return end
    local over = self:isMouseOver()
    local bc = (over and self.backgroundColorMouseOver) or self.backgroundColor
    self:drawRect(0, 0, self.width, self.height, bc.a, bc.r, bc.g, bc.b)
    local b = self.borderColor
    self:drawRectBorder(0, 0, self.width, self.height, b.a, b.r, b.g, b.b)
end

function ISButton:render()
    if self.image then
        -- icon button (bag tabs, container buttons): draw the texture inset,
        -- tinted by textureColor like vanilla ISButton (SIR's window dress
        -- re-inks glyph buttons through this field -- hardcoded white hid that)
        local tc = self.textureColor or { r = 1, g = 1, b = 1, a = 1 }
        if self.forcedWidthImage and self.forcedHeightImage then
            -- vanilla: forced dims pin the mark size regardless of button size
            self:drawTextureScaledAspect(self.image,
                math.floor((self.width - self.forcedWidthImage) / 2),
                math.floor((self.height - self.forcedHeightImage) / 2),
                self.forcedWidthImage, self.forcedHeightImage, tc.a, tc.r, tc.g, tc.b)
        else
            self:drawTextureScaledAspect(self.image, 2, 2, self.width - 4, self.height - 4, tc.a, tc.r, tc.g, tc.b)
        end
    elseif self.title and self.title ~= "" then
        local t = self.textColor
        self:drawTextCentre(self.title, self.width / 2, (self.height - fontMetrics(self.font).h) / 2,
            t.r, t.g, t.b, t.a, self.font)
    end
end

function ISButton:onMouseUp(x, y)
    if self.onclick then self.onclick(self.target, self) end
end

-- ============================================================================
-- ISLabel
-- ============================================================================
-- ============================================================================
-- ISScrollBar
-- ============================================================================
-- Modelled on vanilla ISScrollBar (geometry from :setPosition, draw from
-- :render). It exists here for two reasons that both bit us:
--
--   * it OCCUPIES A COLUMN. 17px on the right of its parent, always. A preview
--     without one shows content sitting in space the game does not have, which
--     is how a lore column looked comfortable in the mock and ran underneath
--     the bar in the game.
--   * it is RESKINNABLE. A mod that dresses the bar (as VPS does) has to be
--     able to see the result; an invisible bar previews as "fine" no matter
--     what it actually looks like.
--
-- The thumb geometry mirrors vanilla's arithmetic so its size tracks the real
-- scroll ratio rather than being a decorative rectangle.
ISScrollBar = ISUIElement:derive("ISScrollBar")

function ISScrollBar:new(parent, vertical)
    local o = ISUIElement:new(0, 0, 17, parent and parent.height or 0)
    setmetatable(o, self)
    self.__index = self
    o.parent = parent
    o.vertical = vertical ~= false
    o.pos = 0
    o.background = true
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.6 }
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    return o
end

function ISScrollBar:initialise()
    local p = self.parent
    if not p then return end
    self.x = (p.width or 0) - 16
    self.y = 0
    self.width = 17
    self.height = p.height or 0
end

function ISScrollBar:render()
    local p = self.parent
    if not p or not self.vertical then return end
    local sh = p.getScrollHeight and p:getScrollHeight() or 0
    if sh <= self.height then return end

    if self.background then
        self:drawRect(4, 0, self.width - 5, self.height,
            self.backgroundColor.a, self.backgroundColor.r,
            self.backgroundColor.g, self.backgroundColor.b)
    end

    local del = self.height / sh
    local boxheight = math.max(math.ceil(del * (self.height - 32)), 8)
    local dif = math.ceil((self.height - 32 - boxheight) * (self.pos or 0))
    self.barx, self.bary = 5, 16 + dif
    self.barwidth, self.barheight = 8, boxheight

    -- Vanilla paints the thumb from three textures; the shape is what matters
    -- for judging a reskin, so it is one rect here.
    self:drawRect(self.barx, self.bary, 9, self.barheight, 1, 0.9, 0.9, 0.9)
    self:drawRectBorder(3, 0, self.width - 4, self.height,
        self.borderColor.a, self.borderColor.r,
        self.borderColor.g, self.borderColor.b)
end

ISLabel = ISUIElement:derive("ISLabel")

function ISLabel:new(x, y, height, name, r, g, b, a, font, center)
    local o = ISUIElement.new(self, x, y, 0, height or 18)
    o.name = name or ""
    o.r, o.g, o.b, o.a = r or 1, g or 1, b or 1, a == nil and 1 or a
    o.font = font or UIFont.Small
    o.center = center
    o.width = getTextManager():MeasureStringX(o.font, o.name)
    return o
end

function ISLabel:setName(n) self.name = n; self.width = getTextManager():MeasureStringX(self.font, n) end
function ISLabel:getWidth() return getTextManager():MeasureStringX(self.font, self.name) end

function ISLabel:render()
    if self.center then
        self:drawTextCentre(self.name, self.width / 2, 0, self.r, self.g, self.b, self.a, self.font)
    else
        self:drawText(self.name, 0, 0, self.r, self.g, self.b, self.a, self.font)
    end
end

-- ============================================================================
-- ISTextEntryBox  (search/input widget)
-- ============================================================================
ISTextEntryBox = ISUIElement:derive("ISTextEntryBox")

function ISTextEntryBox:new(text, x, y, width, height)
    local o = ISUIElement.new(self, x, y, width, height)
    o.text = text or ""
    o.font = UIFont.Medium
    o._focused = false
    o._editable = true
    o.placeholder = nil
    -- the real widget's chrome is java-side: setHasFrame(false) bares it (SIR's
    -- search band does this before laying its own recessed field under the box)
    o._hasFrame = true
    o.javaObject = {
        setHasFrame = function(_, b) o._hasFrame = b and true or false end,
        setTextColor = function() end,
    }
    return o
end

function ISTextEntryBox:initialise() end
function ISTextEntryBox:instantiate() end
function ISTextEntryBox:setEditable(b) self._editable = b and true or false end
function ISTextEntryBox:getText() return self.text end
function ISTextEntryBox:setText(t) self.text = t or "" end
function ISTextEntryBox:getInternalText() return self.text end
function ISTextEntryBox:focus() self._focused = true end
function ISTextEntryBox:unfocus() self._focused = false end
function ISTextEntryBox:isFocused() return self._focused end
function ISTextEntryBox:ignoreFirstInput() end
function ISTextEntryBox:setMaxTextLength(n) end
function ISTextEntryBox:setClearButton(b) end

function ISTextEntryBox:prerender()
    -- java frame bared (setHasFrame(false)): the host draws its own field
    if self._hasFrame == false then return end
    -- honor backgroundColor / borderColor like the real ISTextEntryBox, so a
    -- re-themed field (e.g. the cream order-ticket) renders faithfully headless.
    local bg = self.backgroundColor
    if bg then self:drawRect(0, 0, self.width, self.height, bg.a or 1, bg.r, bg.g, bg.b)
    else self:drawRect(0, 0, self.width, self.height, 0.9, 0.10, 0.10, 0.13) end
    local bd = self.borderColor
    if bd then self:drawRectBorder(0, 0, self.width, self.height, bd.a or 0.7, bd.r, bd.g, bd.b)
    else self:drawRectBorder(0, 0, self.width, self.height, self._focused and 0.95 or 0.6, 0.55, 0.48, 0.2) end
end

function ISTextEntryBox:render()
    local fh = fontMetrics(self.font).h
    local ty = math.floor((self.height - fh) / 2)
    -- pick text/placeholder ink by background luminance (dark text on a light field)
    local bg = self.backgroundColor
    local lightBg = bg and (0.299 * bg.r + 0.587 * bg.g + 0.114 * bg.b) > 0.6
    local tr, tg, tb = 0.95, 0.93, 0.85
    local pr, pg, pb = 0.42, 0.42, 0.48
    -- A LIGHT field is a custom-styled panel (the order box's cream search bar) that
    -- draws its OWN ink text + ghost over the widget — like the real B42 widget, whose
    -- near-white text is invisible on cream. So on a light field the mock draws NOTHING
    -- here; otherwise it'd double the text, offset, in captures. Dark default fields
    -- (other widgets that don't redraw) still render their own text.
    if not lightBg then
        if self.text ~= "" then
            self:drawText(self.text, 6, ty, tr, tg, tb, 1, self.font)
            if self._focused then
                local cw = getTextManager():MeasureStringX(self.font, self.text)
                self:drawRect(6 + cw + 1, ty, 1, fh, 1, 0.9, 0.55, 0.2)
            end
        elseif self.placeholder then
            self:drawText(self.placeholder, 6, ty, pr, pg, pb, 1, self.font)
        end
    end
end

-- ── misc PZ globals panels reference (safe no-op stubs) ─────────────────────
if Keyboard == nil then
    Keyboard = {
        KEY_ESCAPE = 1, KEY_F1 = 59, KEY_TAB = 15, KEY_INSERT = 210,
        KEY_LCONTROL = 29, KEY_RCONTROL = 157, KEY_LSHIFT = 42, KEY_RSHIFT = 54,
        KEY_SPACE = 57, KEY_PERIOD = 52, KEY_P = 25, KEY_SLASH = 53, KEY_COMMA = 51,
    }
end
if isKeyDown == nil then function isKeyDown(k) return false end end
-- getTexture returns a mock whose tostring is the asset path, so draw calls that
-- take a Texture object (e.g. the pin star via getTexture) record the path and
-- the viewer/build resolves the real PNG — same as drawTextureScaled(path).
-- REAL DIMENSIONS, NOT 32x32.
--
-- This stub used to claim 32x32 for every texture in the game. Most draws pass
-- an explicit destination rect and never ask, so it looked harmless -- but any
-- code that TILES, fits, or steps by the source size reads getWidth() and got
-- a lie, and the preview then could not show the resulting artifact.
--
-- Measured: VorpallySauced's journal tiles a 512x512 paper texture over an
-- 846px sheet. In game the 334px remainder held a squashed copy of the whole
-- tile and read as a second crease beside the page fold. Here the same code
-- tiled at 32px, the remainder was 13px, and nothing was visible. The preview
-- said one fold; the screen said two.
--
-- TextureSizes.lua is generated from the same .pack files the game loads
-- (uiview/tools/gen_texture_sizes.py). 32 stays as the fallback for anything
-- outside a pack, which is at least no worse than before.
local TEX_SIZES = {}
pcall(function() TEX_SIZES = require "UIView/TextureSizes" or {} end)

if getTexture == nil then
    function getTexture(path)
        if not path then return nil end
        local base = tostring(path):match("([^/\]+)$") or tostring(path)
        base = base:gsub("%.png$", "")
        local size = TEX_SIZES[base] or TEX_SIZES[tostring(path)]
        local w = size and size[1] or 32
        local h = size and size[2] or 32
        return setmetatable({
            getWidth = function() return w end, getHeight = function() return h end,
            getWidthOrig = function() return w end, getHeightOrig = function() return h end,
            getName = function() return path end,
        }, { __tostring = function() return path end })
    end
end

-- ── ObjectTooltip + ISContextMenu: what the REAL ISToolTipInv needs ─────────
-- With these two present, `vanilla_requires = { "client/ISUI/ISToolTipInv" }`
-- loads and RUNS, so a suite can drive PZ's actual tooltip render instead of a
-- hand-written imitation of it. That matters: the imitation in TooltipLib's
-- dress test omitted `self:setHeight(tooltip:getHeight())` after the measure
-- pass, and the half-empty-tooltip bug (v1.6.3) lived in exactly the gap that
-- omission created — invisible to a green suite for four releases. The real file
-- cannot omit its own lines.
--
-- ObjectTooltip is Java, so it still has to be modelled. Modelled on the
-- decompiled zombie.ui.ObjectTooltip, and faithful in the four ways that have
-- bitten us: `items` is NOT readable from Lua (returns nil, so framework code
-- that wrongly reads it fails here the way it fails in game); Layout.render
-- RETURNS top + the summed item heights; a multi-line label is ONE item spanning
-- lines * lineSpacing; and render EXPANDS the tooltip width to fit content.
if ISContextMenu == nil then
    -- `instance == nil` means "no menu up", which is the path that draws. Vanilla
    -- gates its WHOLE render body on this, so a test that wants a no-op frame
    -- sets ISContextMenu.instance = { visibleCheck = true }.
    ISContextMenu = { instance = nil }
end

if ObjectTooltip == nil then
    ObjectTooltip = {}
    function ObjectTooltip.new()
        local t = {
            _w = 0, _h = 0, _x = 0, _y = 0, _measure = false,
            padLeft = 5, padRight = 5, padTop = 5, padBottom = 5,
            texts = {}, draws = {}, _layouts = {},
        }
        function t.setWidth(s, w) s._w = w end
        function t.getWidth(s) return s._w end
        function t.setHeight(s, h) s._h = h end
        function t.getHeight(s) return s._h end
        function t.setX(s, x) s._x = x end
        function t.getX(s) return s._x end
        function t.setY(s, y) s._y = y end
        function t.getY(s) return s._y end
        function t.setMeasureOnly(s, b) s._measure = b end
        function t.isMeasureOnly(s) return s._measure == true end
        -- vanilla derives this from the tooltip font; use the real metric so a
        -- font-size change moves row heights here the way it does in game.
        function t.getLineSpacing() return getTextManager():getFontHeight(UIFont.Small) + 2 end
        function t.getFont() return UIFont.Small end
        function t.reset(s) s._layouts = {} end
        function t.setItem() end
        function t.setCharacter() end
        function t.setWeightOfStack() end
        function t.DrawText(s, font, str, x, y) s.texts[#s.texts + 1] = { str = str, x = x, y = y } end
        function t.DrawTextRight(s, font, str, x, y) s.texts[#s.texts + 1] = { str = str, x = x, y = y, right = true } end
        function t.DrawTextureScaledColor(s, tex, x, y, w, h, r, g, b, a)
            s.draws[#s.draws + 1] = { tex = tex, x = x, y = y, w = w, h = h, r = r, g = g, b = b, a = a }
        end
        function t.beginLayout(s)
            local L = { _items = {} }
            function L.addItem()
                local it = {
                    hasValue = false, rightJustify = false, progressFraction = -1,
                    labelWidth = 0, valueWidth = 0, valueWidthRight = 0,
                    progressWidth = 0, height = s:getLineSpacing(),
                }
                function it.setLabel(i, txt, r, g, b, a) i.label = txt end
                function it.setValue(i, v) i.value = v; i.hasValue = true; i.rightJustify = true end
                function it.setValueRight(i, v) i.value = tostring(v); i.hasValue = true; i.rightJustify = true end
                function it.setProgress(i, f, r, g, b, a) i.progressFraction = f; i.hasValue = true end
                L._items[#L._items + 1] = it
                return it
            end
            function L.setMinValueWidth(l, w) l._minValueWidth = w end
            function L.setMinLabelWidth(l, w) l._minLabelWidth = w end
            function L.render(l, x, y, ui)
                local ls = s:getLineSpacing()
                local widest = 0
                for i = 1, #l._items do
                    local it = l._items[i]
                    local tm = getTextManager()
                    it.labelWidth = it.label and tm:MeasureStringX(UIFont.Small, tostring(it.label)) or 0
                    local w = it.labelWidth
                    if it.hasValue and it.value then
                        local vw = tm:MeasureStringX(UIFont.Small, tostring(it.value))
                        if it.rightJustify then it.valueWidthRight = vw else it.valueWidth = vw end
                        w = w + 20 + vw
                    end
                    if w > widest then widest = w end
                    -- calcSizes counts embedded newlines: ONE item, many lines
                    local lines = 1
                    if it.label then
                        for _ in string.gmatch(tostring(it.label), "\n") do lines = lines + 1 end
                    end
                    it.height = ls * lines
                    y = y + it.height
                end
                if (x or 0) + widest + s.padRight > s:getWidth() then
                    s:setWidth((x or 0) + widest + s.padRight)
                end
                return y
            end
            s._layouts[#s._layouts + 1] = L
            return L
        end
        function t.endLayout() end
        return t
    end
end

-- ── expose metrics for the renderer/scenes ──────────────────────────────────
UIView_fontMetrics = fontMetrics

return {
    ISBaseObject = ISBaseObject,
    ISUIElement = ISUIElement,
    ISPanel = ISPanel,
    ISButton = ISButton,
    ISLabel = ISLabel,
    fontMetrics = fontMetrics,
}
