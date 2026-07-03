--[[
    TooltipLib panel dress — ISToolTipInv hook contract
    ===================================================
    Loads the REAL TooltipLib Hook.lua against a vanilla-shaped ISToolTipInv
    mock (measure DoTooltip -> flat box draw -> real DoTooltip, the exact
    B42 render sequence) and locks the dress contract on the item surface:

      - the dress draws exactly ONCE per render (real pass only), before
        vanilla/provider content, with final tooltip geometry
      - vanilla's flat box is suppressed during the render (alphas zeroed)
        and restored after — the shared panel fields never leak a zero
      - a foreign framework that bypasses DoTooltip gets its box back from
        the next frame on (foreign-owner latch), and a healthy panel re-arms
      - active()=false stands down; a draw error clears the dress (fail-open)
      - setPanelDress/clearPanelDress validate and scope by owner id
]]

local Assert = PZTestKit.Assert

require "UIView/UIMock"

if isClient == nil then function isClient() return false end end
if isServer == nil then function isServer() return false end end

-- ── vanilla-shaped ISToolTipInv mock (must exist BEFORE Hook.lua loads) ─────
-- Real flow (ISToolTipInv.lua): measure DoTooltip -> clamp/reposition ->
-- drawRect/drawRectBorder from backgroundColor/borderColor -> real DoTooltip.
-- boxRec captures the alphas AT box-draw time — that's what the screen gets.
ISToolTipInv = ISToolTipInv or {}

local boxRec = {}
local seq = {}   -- paint-order log: "dress" / "layout" entries

local function vanillaImpl(self)
    local tt = self.tooltip
    tt:setWidth(50)
    tt:setMeasureOnly(true)
    if self.item then self.item:DoTooltip(tt) end
    tt:setMeasureOnly(false)
    boxRec.bgA = self.backgroundColor.a
    boxRec.bdA = self.borderColor.a
    if self.item then self.item:DoTooltip(tt) end
end

ISToolTipInv.render = function(self)
    return (self._impl or vanillaImpl)(self)
end

require "TooltipLib/Core"
require "TooltipLib/Hook"
triggerEvent("OnGameStart")                  -- InstallHook wraps our mock
local hookedRender = ISToolTipInv.render     -- stable capture (later OnGameStart
                                             -- triggers may re-wrap the global)

-- ── fixtures ────────────────────────────────────────────────────────────────
local ItemProto = {}
function ItemProto.DoTooltip(item, tooltip)
    item._doCalls = (item._doCalls or 0) + 1
    tooltip:setWidth(200)
    tooltip:setHeight(80)
end
function ItemProto.DoTooltipEmbedded(item, tooltip, layout, offset) end
function ItemProto.getID(item) return item._id end
local ItemMT = { __index = ItemProto }

local nextId = 9000
local function makeItem()
    nextId = nextId + 1
    return setmetatable({ _id = nextId }, ItemMT)
end

local function makeTT()
    local t = { _w = 0, _h = 0, _x = 0, _y = 0, _measure = false }
    function t.setWidth(self, w) self._w = w end
    function t.getWidth(self) return self._w end
    function t.setHeight(self, h) self._h = h end
    function t.getHeight(self) return self._h end
    function t.setX(self, x) self._x = x end
    function t.getX(self) return self._x end
    function t.setY(self, y) self._y = y end
    function t.getY(self) return self._y end
    function t.setMeasureOnly(self, b) self._measure = b end
    function t.isMeasureOnly(self) return self._measure end
    function t.getLineSpacing(self) return 14 end
    function t.beginLayout(self)
        return {
            setMinValueWidth = function() end,
            render = function(_, x, y, tooltip)
                seq[#seq + 1] = "layout"
                return 40
            end,
        }
    end
    function t.endLayout(self, layout) end
    function t.DrawText(self, ...) end
    function t.DrawTextRight(self, ...) end
    t.draws = {}
    function t.DrawTextureScaledColor(self, tex, x, y, w, h, r, g, b, a)
        t.draws[#t.draws + 1] = { tex = tex, x = x, y = y, w = w, h = h,
                                  r = r, g = g, b = b, a = a }
    end
    return t
end

-- the framework accent line: a nil-texture 2px-wide draw at x=1
local function findBarDraw(tt)
    for _, d in ipairs(tt.draws) do
        if d.tex == nil and d.x == 1 and d.w == 2 then return d end
    end
    return nil
end

local function makePanel(item, impl)
    return {
        item = item,
        tooltip = makeTT(),
        backgroundColor = { r = 0, g = 0, b = 0, a = 0.5 },
        borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 },
        _impl = impl,
        setHeight = function(self, h) self._panelH = h end,
        setWidth = function(self, w) self._panelW = w end,
    }
end

-- recording dress; draw signature per the setPanelDress contract
local function makeDress(opts)
    opts = opts or {}
    local d = { calls = {} }
    d.spec = {
        id = opts.id or "TestDress",
        active = opts.active,
        surfaces = opts.surfaces,
        draw = opts.draw or function(panel, tooltip, w, h, surface)
            d.calls[#d.calls + 1] = {
                w = w, h = h, surface = surface,
                measure = (tooltip and tooltip:isMeasureOnly()) or false,
            }
            seq[#seq + 1] = "dress"
        end,
    }
    return d
end

local function reset()
    TooltipLib.clearPanelDress("TestDress")
    boxRec.bgA, boxRec.bdA = nil, nil
    for i = #seq, 1, -1 do seq[i] = nil end
end

local tests = {}

tests["baseline_no_dress_vanilla_box_untouched"] = function()
    reset()
    local p = makePanel(makeItem())
    hookedRender(p)
    local ok = Assert.equal(boxRec.bgA, 0.5, "bg alpha at box draw")
    ok = Assert.equal(boxRec.bdA, 1, "border alpha at box draw") and ok
    ok = Assert.equal(p.item._doCalls, 2, "vanilla DoTooltip ran both passes") and ok
    return ok
end

tests["dress_draws_once_real_pass_final_geometry"] = function()
    reset()
    local d = makeDress()
    TooltipLib.setPanelDress(d.spec)
    local p = makePanel(makeItem())
    hookedRender(p)
    local ok = Assert.equal(#d.calls, 1, "one draw per render (real pass only)")
    ok = Assert.isFalse(d.calls[1] and d.calls[1].measure or false, "not on the measure pass") and ok
    ok = Assert.equal(d.calls[1] and d.calls[1].w, 200, "measured width") and ok
    ok = Assert.equal(d.calls[1] and d.calls[1].h, 80, "measured height") and ok
    ok = Assert.equal(d.calls[1] and d.calls[1].surface, "item", "surface tag") and ok
    ok = Assert.equal(p.item._doCalls, 2, "vanilla content still rendered both passes") and ok
    reset()
    return ok
end

tests["vanilla_box_suppressed_then_restored"] = function()
    reset()
    local d = makeDress()
    TooltipLib.setPanelDress(d.spec)
    local p = makePanel(makeItem())
    hookedRender(p)
    local ok = Assert.equal(boxRec.bgA, 0, "bg alpha zero at box-draw time")
    ok = Assert.equal(boxRec.bdA, 0, "border alpha zero at box-draw time") and ok
    ok = Assert.equal(p.backgroundColor.a, 0.5, "bg alpha restored after render") and ok
    ok = Assert.equal(p.borderColor.a, 1, "border alpha restored after render") and ok
    reset()
    return ok
end

tests["active_false_stands_down_frame"] = function()
    reset()
    local d = makeDress({ active = function() return false end })
    TooltipLib.setPanelDress(d.spec)
    local p = makePanel(makeItem())
    hookedRender(p)
    local ok = Assert.equal(#d.calls, 0, "no dress draw while inactive")
    ok = Assert.equal(boxRec.bgA, 0.5, "vanilla box untouched while inactive") and ok
    ok = Assert.notNil(TooltipLib.getPanelDress(), "dress stays registered") and ok
    reset()
    return ok
end

tests["surfaces_optout_leaves_item_vanilla"] = function()
    reset()
    local d = makeDress({ surfaces = { object = true } })
    TooltipLib.setPanelDress(d.spec)
    local p = makePanel(makeItem())
    hookedRender(p)
    local ok = Assert.equal(#d.calls, 0, "item surface not opted in")
    ok = Assert.equal(boxRec.bgA, 0.5, "vanilla box untouched") and ok
    reset()
    return ok
end

tests["draw_error_clears_dress_fail_open"] = function()
    reset()
    TooltipLib.setPanelDress({ id = "TestDress", draw = function() error("boom") end })
    local p = makePanel(makeItem())
    hookedRender(p)
    local ok = Assert.isNil(TooltipLib.getPanelDress(), "dress cleared on draw error")
    ok = Assert.equal(p.backgroundColor.a, 0.5, "bg alpha restored despite error") and ok
    ok = Assert.equal(p.borderColor.a, 1, "border alpha restored despite error") and ok
    boxRec.bgA = nil
    hookedRender(makePanel(makeItem()))
    ok = Assert.equal(boxRec.bgA, 0.5, "next render is fully vanilla") and ok
    return ok
end

tests["foreign_owner_latch_and_rearm"] = function()
    reset()
    local d = makeDress()
    TooltipLib.setPanelDress(d.spec)
    -- foreign framework: replaces the render path, draws its own panel,
    -- never calls item:DoTooltip, never touches self.tooltip
    local foreignImpl = function(self)
        boxRec.bgA = self.backgroundColor.a
        boxRec.bdA = self.borderColor.a
    end
    local p = makePanel(makeItem(), foreignImpl)

    hookedRender(p)   -- frame 1: foreign discovered (documented one-frame blank)
    local ok = Assert.equal(#d.calls, 0, "foreign panel never dressed")
    ok = Assert.equal(boxRec.bgA, 0, "frame 1 suppressed before discovery") and ok
    ok = Assert.equal(p.backgroundColor.a, 0.5, "alphas restored after frame 1") and ok

    hookedRender(p)   -- frame 2: latch holds, vanilla box left alone
    ok = Assert.equal(boxRec.bgA, 0.5, "no suppression while foreign owns the panel") and ok
    ok = Assert.equal(#d.calls, 0, "still no dress draw") and ok

    -- healthy panel again: wrapper fires, latch releases, dress resumes
    local p2 = makePanel(makeItem())
    hookedRender(p2)
    hookedRender(p2)
    ok = Assert.equal(boxRec.bgA, 0, "suppression re-armed on an owned panel") and ok
    ok = Assert.greater(#d.calls, 0, "dress draws again") and ok
    reset()
    return ok
end

tests["provider_path_dress_under_content"] = function()
    reset()
    local probeRan = false
    TooltipLib.registerProvider({
        id = "DressPathProbe",
        target = "item",
        enabled = function() return true end,
        callback = function(ctx) probeRan = true end,
        description = "dress-order probe",
    })
    local d = makeDress()
    TooltipLib.setPanelDress(d.spec)
    local p = makePanel(makeItem())
    hookedRender(p)
    local ok = Assert.isTrue(probeRan, "provider dispatch ran")
    ok = Assert.equal(#d.calls, 1, "one dress draw with providers active") and ok
    -- paint order: measure layout, then (real pass) dress BEFORE layout
    ok = Assert.equal(seq[1], "layout", "measure-pass layout first") and ok
    ok = Assert.equal(seq[2], "dress", "dress opens the real pass") and ok
    ok = Assert.equal(seq[3], "layout", "content paints over the dress") and ok
    TooltipLib.removeProvider("DressPathProbe")
    reset()
    return ok
end

tests["accent_channel_framework_draws_one_bar"] = function()
    reset()
    TooltipLib.registerProvider({
        id = "AccentProbe",
        target = "item",
        enabled = function() return true end,
        callback = function(ctx) end,
        postRender = function(ctx) ctx:setAccentColor({ 0.9, 0.3, 0.3, 1 }) end,
        description = "accent channel probe",
    })
    local p = makePanel(makeItem())
    hookedRender(p)
    local bar = findBarDraw(p.tooltip)
    local ok = Assert.notNil(bar, "framework drew the accent line")
    ok = Assert.nearEqual(bar and bar.r or 0, 0.9, 0.001, "declared colour used") and ok
    local n = 0
    for _, d in ipairs(p.tooltip.draws) do
        if d.tex == nil and d.x == 1 and d.w == 2 then n = n + 1 end
    end
    ok = Assert.equal(n, 1, "exactly one bar (real pass only, one source)") and ok
    TooltipLib.removeProvider("AccentProbe")
    return ok
end

tests["accent_last_write_wins"] = function()
    reset()
    TooltipLib.registerProvider({
        id = "AccentTheme",
        target = "item",
        priority = TooltipLib.Priorities.FIRST,
        enabled = function() return true end,
        callback = function(ctx) end,
        postRender = function(ctx) ctx:setAccentColor({ 0.1, 0.1, 0.1, 1 }) end,
        description = "theme colour (first)",
    })
    TooltipLib.registerProvider({
        id = "AccentTier",
        target = "item",
        priority = 100,
        enabled = function() return true end,
        callback = function(ctx) end,
        postRender = function(ctx) ctx:setAccentColor({ 0.6, 0.2, 0.8, 1 }) end,
        description = "tier colour (later, wins)",
    })
    local p = makePanel(makeItem())
    hookedRender(p)
    local bar = findBarDraw(p.tooltip)
    local ok = Assert.notNil(bar, "bar drawn")
    ok = Assert.nearEqual(bar and bar.b or 0, 0.8, 0.001, "later provider's colour wins") and ok
    TooltipLib.removeProvider("AccentTheme")
    TooltipLib.removeProvider("AccentTier")
    return ok
end

tests["accent_reaches_dress_next_frame_no_bar"] = function()
    reset()
    TooltipLib.registerProvider({
        id = "AccentProbe2",
        target = "item",
        enabled = function() return true end,
        callback = function(ctx) end,
        postRender = function(ctx) ctx:setAccentColor({ 0.2, 0.8, 0.4, 1 }) end,
        description = "accent channel probe",
    })
    local d = makeDress()
    TooltipLib.setPanelDress(d.spec)
    local calls, seen = 0, {}
    d.spec.draw = function(panel, tooltip, w, h, surface, accent)
        calls = calls + 1
        seen[calls] = accent
    end
    local p = makePanel(makeItem())
    hookedRender(p)   -- frame 1: providers declare, dress drew before them
    hookedRender(p)   -- frame 2: dress catches up from the accent cache
    local ok = Assert.equal(calls, 2, "one dress draw per render")
    ok = Assert.isNil(seen[1], "frame 1: accent not yet known to the dress") and ok
    ok = Assert.notNil(seen[2], "frame 2: dress receives the accent") and ok
    ok = Assert.nearEqual(seen[2] and seen[2][2] or 0, 0.8, 0.001, "the declared colour") and ok
    ok = Assert.isNil(findBarDraw(p.tooltip), "no framework bar while dressed") and ok
    TooltipLib.removeProvider("AccentProbe2")
    reset()
    return ok
end

tests["callback_declared_accent_reaches_dress_same_frame"] = function()
    reset()
    TooltipLib.registerProvider({
        id = "AccentWarm",
        target = "item",
        enabled = function() return true end,
        -- CALLBACK declaration (the recommended path): runs on the measure
        -- pass, which warms the accent cache before this same render's real
        -- pass — the dress never flashes its default rail
        callback = function(ctx) ctx:setAccentColor({ 0.1, 0.2, 0.9, 1 }) end,
        description = "callback-declared accent",
    })
    local d = makeDress()
    TooltipLib.setPanelDress(d.spec)
    local calls, seen = 0, {}
    d.spec.draw = function(panel, tooltip, w, h, surface, accent)
        calls = calls + 1
        seen[calls] = accent
    end
    local p = makePanel(makeItem())
    hookedRender(p)   -- ONE render: measure pass warms, real pass reads
    local ok = Assert.equal(calls, 1, "one real-pass draw")
    ok = Assert.notNil(seen[1], "accent known on the FIRST frame") and ok
    ok = Assert.nearEqual(seen[1] and seen[1][3] or 0, 0.9, 0.001, "the declared colour") and ok
    TooltipLib.removeProvider("AccentWarm")
    reset()
    return ok
end

tests["set_clear_validation"] = function()
    reset()
    local ok = Assert.isFalse(TooltipLib.setPanelDress(nil), "nil spec rejected")
    ok = Assert.isFalse(TooltipLib.setPanelDress({ id = "X" }), "missing draw rejected") and ok
    ok = Assert.isFalse(TooltipLib.setPanelDress({ draw = function() end }), "missing id rejected") and ok
    ok = Assert.isTrue(TooltipLib.setPanelDress({ id = "TestDress", draw = function() end }), "valid spec accepted") and ok
    ok = Assert.isFalse(TooltipLib.clearPanelDress("SomeoneElse"), "wrong owner cannot clear") and ok
    ok = Assert.notNil(TooltipLib.getPanelDress(), "dress survives wrong-owner clear") and ok
    ok = Assert.isTrue(TooltipLib.clearPanelDress("TestDress"), "owner clears") and ok
    ok = Assert.isNil(TooltipLib.getPanelDress(), "slot empty after clear") and ok
    return ok
end

return tests
