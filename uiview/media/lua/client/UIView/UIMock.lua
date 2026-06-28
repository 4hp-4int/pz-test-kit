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
      - Text width is APPROXIMATED per font (avg glyph width). Layouts that flow
        on MeasureStringX are close, not pixel-exact. Tune FONT below if needed.
      - Textures are recorded by name as placeholder boxes (no pixels headless).
]]

local Recorder = require "UIView/Recorder"

-- ── Screen + core stubs ─────────────────────────────────────────────────────
local SCREEN_W, SCREEN_H = 1920, 1080

local _core = {
    getScreenWidth  = function(self) return SCREEN_W end,
    getScreenHeight = function(self) return SCREEN_H end,
    getOptionFontSizeReal = function(self) return 1 end,
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
local function fontMetrics(font)
    return FONT[font] or FONT.Small
end

local _textManager = {
    MeasureStringX = function(self, font, str)
        if not str then return 0 end
        return math.floor(#tostring(str) * fontMetrics(font).w + 0.5)
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

function ISUIElement:instantiate() end
function ISUIElement:createChildren() end

-- geometry --------------------------------------------------------------------
function ISUIElement:getX() return self.x end
function ISUIElement:getY() return self.y end
function ISUIElement:getWidth() return self.width end
function ISUIElement:getHeight() return self.height end
function ISUIElement:setX(x) self.x = x end
function ISUIElement:setY(y) self.y = y end
function ISUIElement:setWidth(w) self.width = w end
function ISUIElement:setHeight(h) self.height = h end
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

function ISUIElement:drawRect(x, y, w, h, a, r, g, b)
    if self.isCollapsed then return end
    local c = rgba(r, g, b, a)
    Recorder.push({ op = "rect", x = self:getAbsoluteX() + x, y = self:getAbsoluteY() + y,
        w = w, h = h, r = c.r, g = c.g, b = c.b, a = c.a, el = self._uid })
end
ISUIElement.drawRectStatic = ISUIElement.drawRect

function ISUIElement:drawRectBorder(x, y, w, h, a, r, g, b)
    local c = rgba(r, g, b, a)
    Recorder.push({ op = "rectborder", x = self:getAbsoluteX() + x, y = self:getAbsoluteY() + y,
        w = w, h = h, r = c.r, g = c.g, b = c.b, a = c.a, el = self._uid })
end
ISUIElement.drawRectBorderStatic = ISUIElement.drawRectBorder

local function pushText(self, str, x, y, r, g, b, a, font, align)
    if self.isCollapsed or str == nil then return end
    local c = rgba(r, g, b, a)
    Recorder.push({ op = "text", str = tostring(str),
        x = self:getAbsoluteX() + x, y = self:getAbsoluteY() + y,
        r = c.r, g = c.g, b = c.b, a = c.a,
        font = font or UIFont.Small, align = align, el = self._uid })
end

function ISUIElement:drawText(str, x, y, r, g, b, a, font)
    pushText(self, str, x, y, r, g, b, a, font, "left")
end
ISUIElement.drawTextStatic = ISUIElement.drawText
ISUIElement.drawTextUntrimmed = ISUIElement.drawText
function ISUIElement:drawTextCentre(str, x, y, r, g, b, a, font)
    pushText(self, str, x, y, r, g, b, a, font, "centre")
end
ISUIElement.drawTextCentreStatic = ISUIElement.drawTextCentre
function ISUIElement:drawTextRight(str, x, y, r, g, b, a, font)
    pushText(self, str, x, y, r, g, b, a, font, "right")
end
ISUIElement.drawTextRightStatic = ISUIElement.drawTextRight

function ISUIElement:drawTextZoomed(str, x, y, zoom, r, g, b, a, font)
    pushText(self, str, x, y, r, g, b, a, font, "left")
end

local function pushTexture(self, name, x, y, w, h, a, r, g, b)
    local c = rgba(r, g, b, a)
    Recorder.push({ op = "texture", name = name and tostring(name) or "",
        x = self:getAbsoluteX() + x, y = self:getAbsoluteY() + y, w = w or 0, h = h or 0,
        r = c.r, g = c.g, b = c.b, a = c.a, el = self._uid })
end

function ISUIElement:drawTextureScaled(tex, x, y, w, h, a, r, g, b)
    pushTexture(self, tex, x, y, w, h, a, r, g, b)
end
ISUIElement.drawTextureScaledColor = ISUIElement.drawTextureScaled
ISUIElement.drawTextureScaledStatic = ISUIElement.drawTextureScaled
function ISUIElement:drawTexture(tex, x, y, a, r, g, b)
    -- unknown native size; record a small marker box. Mods that need real size
    -- use drawTextureScaled.
    pushTexture(self, tex, x, y, 32, 32, a, r, g, b)
end
ISUIElement.drawTextureStatic = ISUIElement.drawTexture
function ISUIElement:drawTextureScaledAspect(tex, x, y, w, h, a, r, g, b)
    pushTexture(self, tex, x, y, w, h, a, r, g, b)
end

function ISUIElement:drawItemIcon(item, x, y, a, w, h)
    local name = "item"
    if item and item.getName then local ok, n = pcall(function() return item:getName() end); if ok and n then name = n end end
    Recorder.push({ op = "itemicon", name = name,
        x = self:getAbsoluteX() + x, y = self:getAbsoluteY() + y, w = w or 32, h = h or 32,
        a = a == nil and 1 or a, el = self._uid })
end

-- stencil / scroll no-ops mods sometimes call
function ISUIElement:setStencilRect() end
function ISUIElement:clearStencilRect() end
function ISUIElement:suspendStencil() end
function ISUIElement:resumeStencil() end
function ISUIElement:updateScrollbars() end
function ISUIElement:setScrollHeight() end
function ISUIElement:setScrollWidth() end
function ISUIElement:getScrollHeight() return 0 end
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

function ISButton:prerender()
    local over = self:isMouseOver()
    local bc = (over and self.backgroundColorMouseOver) or self.backgroundColor
    self:drawRect(0, 0, self.width, self.height, bc.a, bc.r, bc.g, bc.b)
    local b = self.borderColor
    self:drawRectBorder(0, 0, self.width, self.height, b.a, b.r, b.g, b.b)
    if self.image then
        -- icon button (bag tabs, container buttons): draw the texture inset
        self:drawTextureScaledAspect(self.image, 2, 2, self.width - 4, self.height - 4, 1, 1, 1, 1)
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
        KEY_SPACE = 57, KEY_PERIOD = 52, KEY_P = 25,
    }
end
if isKeyDown == nil then function isKeyDown(k) return false end end
-- getTexture returns a mock whose tostring is the asset path, so draw calls that
-- take a Texture object (e.g. the pin star via getTexture) record the path and
-- the viewer/build resolves the real PNG — same as drawTextureScaled(path).
if getTexture == nil then
    function getTexture(path)
        if not path then return nil end
        return setmetatable({
            getWidth = function() return 32 end, getHeight = function() return 32 end,
            getWidthOrig = function() return 32 end, getHeightOrig = function() return 32 end,
            getName = function() return path end,
        }, { __tostring = function() return path end })
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
