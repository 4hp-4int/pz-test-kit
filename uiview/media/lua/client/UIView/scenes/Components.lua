--[[
    UIView — Scene: SIR component gallery
    =====================================
    The design surface for the visual language. Renders each palette component in
    isolation using the REAL draw code (pal_ui's drawChip/drawPinStar + the
    pal_theme tokens), so tweaking pal_theme updates every swatch here. This is
    where we iterate colour/spacing/type before touching a live state.
]]

require "UIView/UIMock"
UIView_setScreen(960, 720)
require "palette/pal_ui"
local SP = _G.SaucePalette

-- pins stub so drawPinStar can show all three states
local pinned = {}
SP.Pins = { isPinned = function(c) return pinned[c] == true end,
            toggle = function(c) pinned[c] = not pinned[c] or nil end }

local T = require "palette/pal_theme"
local UIFont = UIFont

local CATS = { "world", "vehicle", "craft", "build", "read", "inspect", "equip",
               "eat", "drink", "med", "use", "open", "edit", "place", "lookup", "item", "action" }
local TAGS = { "need", "habit", "context", "here", "pin", "block", "source" }
local TONES = { "make", "consume", "tool", "missing" }

local Comp = {}

function Comp.build()
    local root = SaucePaletteUI:new(0)
    root:initialise()
    root.width, root.height = 960, 720

    local pinnedCmd = { label = "pinned" }
    pinned[pinnedCmd] = true
    local plainCmd = { label = "plain" }

    root.render = function(self)
        local function rgb(c) return c[1], c[2], c[3] end
        local function head(text, x, y)
            self:drawText(text, x, y, 0.62, 0.60, 0.72, 1, UIFont.Small)
        end
        -- backdrop
        self:drawRect(0, 0, self.width, self.height, 1, rgb(T.color.panelBg))

        -- ── category chips ──
        head("CATEGORY CHIPS", 18, 14)
        local x, y = 18, 34
        for i, c in ipairs(CATS) do
            self:drawChip(c, x, y, 1)
            x = x + 96
            if i % 8 == 0 then x = 18; y = y + 30 end
        end

        -- ── tags (right-side "why") ──
        y = y + 44
        head("TAGS", 18, y - 18)
        x = 18
        for _, key in ipairs(TAGS) do
            local col = T.color.tag[key]
            self:drawRect(x, y, 10, 10, 1, rgb(col))
            self:drawText(key, x + 16, y - 2, col[1], col[2], col[3], 1, UIFont.Small)
            x = x + 120
        end

        -- ── detail-pane ingredient tones ──
        y = y + 40
        head("INGREDIENT TONES", 18, y - 18)
        x = 18
        for _, key in ipairs(TONES) do
            local col = T.color.tone[key]
            local pre = (key == "make") and "+ " or "- "
            self:drawText(pre .. key, x, y, col[1], col[2], col[3], 1, UIFont.Small)
            x = x + 130
        end

        -- ── pin star states (drawPinStar uses a fixed gutter x, so stack them) ──
        y = y + 40
        head("PIN STAR", 18, y - 18)
        local rows = { { "ghost (every row)", plainCmd, false },
                       { "selected (invite)", plainCmd, true },
                       { "pinned", pinnedCmd, false } }
        for i, r in ipairs(rows) do
            local ry = y + (i - 1) * 22
            self:drawPinStar(ry, r[2], r[3])
            self:drawText(r[1], 18 + 26, ry + 2, 0.78, 0.76, 0.62, 1, UIFont.Small)
        end
        y = y + 2 * 22

        -- ── text ramp ──
        y = y + 48
        head("TEXT", 18, y - 18)
        self:drawText("primary label", 18, y, rgb(T.color.text), 1, UIFont.Medium)
        self:drawText("secondary / hint", 220, y, rgb(T.color.textDim), 1, UIFont.Small)
        self:drawText("muted / disabled", 380, y, rgb(T.color.textMute), 1, UIFont.Small)
        self:drawText("match", 540, y, rgb(T.color.match), 1, UIFont.Medium)

        -- ── surfaces ──
        y = y + 40
        head("SURFACES", 18, y - 18)
        local sw = { { "panelBg", T.color.panelBg }, { "entryBg", T.color.entryBg },
                     { "selBg", T.color.selBg }, { "panelBorder", T.color.panelBorder } }
        x = 18
        for _, s in ipairs(sw) do
            self:drawRect(x, y, 90, 26, 1, rgb(s[2]))
            self:drawRectBorder(x, y, 90, 26, 1, 0.5, 0.5, 0.5)
            self:drawText(s[1], x, y + 30, 0.7, 0.7, 0.7, 1, UIFont.Small)
            x = x + 120
        end
    end

    return root
end

return Comp
